// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

import {PolicyLib} from "./libraries/PolicyLib.sol";
import {TwapLib} from "./libraries/TwapLib.sol";
import {PerformanceLib} from "./libraries/PerformanceLib.sol";

/// @title AvalHook
/// @notice Uniswap v4 hook for curated liquidity vaults. An operator (AI agent) moves each vault's range under
///         on-chain hard limits; the vault owner posts a bond that is slashed to LPs on underperformance (M2).
/// @dev One hook per chain, one pool per pair, many vaults per pool (position salt = vaultId).
///      Thanks to v4's `noSelfCall`, the hook's own initialize/modifyLiquidity calls skip its callbacks, so
///      `beforeInitialize` / `beforeAddLiquidity` / `beforeRemoveLiquidity` simply revert for everyone else.
contract AvalHook is BaseHook, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeTransferLib for ERC20;
    using TwapLib for TwapLib.Oracle;

    // ------------------------------------------------------------------
    // Platform constants
    // ------------------------------------------------------------------

    int24 public constant TICK_SPACING = 60;
    /// @notice Dynamic fee parameters, in pips (1e6 = 100%).
    uint24 public constant BASE_FEE = 500;
    uint24 public constant MAX_FEE = 10_000;
    uint24 public constant FEE_SLOPE_PER_TICK = 50;
    uint24 public constant FREE_DEVIATION_TICKS = 10;

    /// @notice The bond token (mUSDC). One side of every pair must be this token.
    address public immutable bondToken;
    /// @notice TWAP window in seconds used for every limit check and valuation.
    uint32 public immutable twapWindow;
    /// @notice Minimum seconds between oracle checkpoints.
    uint32 public immutable twapGranularity;

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Action {
        WITHDRAW,
        REBALANCE
    }

    struct PoolInfo {
        bool initialized;
        bool bondIsToken0;
    }

    struct Vault {
        PoolKey key;
        address owner;
        address operator;
        PolicyLib.Policy policy;
        // position
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        // accounting (never derived from balanceOf)
        uint256 idle0;
        uint256 idle1;
        uint256 totalShares;
        uint256 pending0;
        uint256 pending1;
        uint256 bond;
        // epochs
        uint64 epoch;
        uint64 epochStart;
        uint64 lastRebalance;
        uint16 rebalancesThisEpoch;
    }

    struct PendingDeposit {
        uint64 epoch;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Conversion rate fixed when an epoch's queued deposits are activated.
    /// @dev shares = value(amounts at sqrtPriceX96) * shareNum / valueDen.
    struct EpochRate {
        uint160 sqrtPriceX96;
        uint256 shareNum;
        uint256 valueDen;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(address token => bool) public isAllowedToken;
    mapping(PoolId => PoolInfo) public pools;
    mapping(PoolId => TwapLib.Oracle) internal _oracles;

    uint256 public nextVaultId = 1;
    mapping(uint256 vaultId => Vault) internal _vaults;
    mapping(uint256 vaultId => mapping(address user => uint256)) public sharesOf;
    mapping(uint256 vaultId => mapping(address user => PendingDeposit)) public pendingDeposits;
    mapping(uint256 vaultId => mapping(uint64 epoch => EpochRate)) public epochRates;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event VaultCreated(
        uint256 indexed vaultId, PoolId indexed poolId, address indexed owner, address operator, uint256 bond
    );
    event PolicyUpdated(uint256 indexed vaultId);
    event Deposited(uint256 indexed vaultId, address indexed user, uint64 epoch, uint256 amount0, uint256 amount1);
    event DepositCancelled(uint256 indexed vaultId, address indexed user, uint256 amount0, uint256 amount1);
    event SharesClaimed(uint256 indexed vaultId, address indexed user, uint64 epoch, uint256 shares);
    event Withdrawn(uint256 indexed vaultId, address indexed user, uint256 shares, uint256 amount0, uint256 amount1);
    event Rebalanced(
        uint256 indexed vaultId, int24 tickLower, int24 tickUpper, uint128 liquidity, int24 twapTick, int24 spotTick
    );
    event EpochSettled(
        uint256 indexed vaultId,
        uint64 indexed epoch,
        int24 twapTick,
        uint256 vaultValue,
        uint256 totalShares,
        uint256 depositValue,
        uint256 sharesMinted
    );

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error OnlyAvalPools();
    error OnlyHookLiquidity();
    error InvalidPoolKey();
    error TokenNotAllowed();
    error ZeroAddress();
    error ZeroAmount();
    error VaultNotFound();
    error OnlyOwner();
    error OnlyOperator();
    error PolicyLocked();
    error NothingPending();
    error InsufficientShares();
    error Slippage();
    error EpochNotOver();
    error CooldownActive();
    error TooManyRebalances();
    error InvalidRange();
    error InvalidWidth();
    error RangeTooFarFromTwap();
    error SpotTooFarFromTwap();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @param _poolManager The v4 PoolManager.
    /// @param _bondToken The bond token (mUSDC); must be in `allowedTokens`.
    /// @param allowedTokens Token allowlist (immutable after deployment).
    /// @param _twapWindow TWAP window in seconds (> 0).
    constructor(IPoolManager _poolManager, address _bondToken, address[] memory allowedTokens, uint32 _twapWindow)
        BaseHook(_poolManager)
    {
        if (_bondToken == address(0)) revert ZeroAddress();
        if (_twapWindow == 0) revert ZeroAmount();
        bondToken = _bondToken;
        twapWindow = _twapWindow;
        uint32 granularity = _twapWindow / uint32(TwapLib.CARDINALITY / 2);
        twapGranularity = granularity == 0 ? 1 : granularity;
        for (uint256 i; i < allowedTokens.length; ++i) {
            isAllowedToken[allowedTokens[i]] = true;
        }
        isAllowedToken[_bondToken] = true;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------
    // Vault lifecycle
    // ------------------------------------------------------------------

    /// @notice Creates a vault on the pool `key`, initializing the pool at `sqrtPriceX96` if it doesn't exist.
    /// @param key Pool key: allowlisted pair with the bond token on one side, dynamic fee, `TICK_SPACING`, this hook.
    /// @param policy Rebalancing policy, within `PolicyLib` bounds.
    /// @param operator Address allowed to call `rebalance()`.
    /// @param bondAmount Bond (in bond token) pulled from the caller.
    /// @param sqrtPriceX96 Initial price, only used if the pool is not initialized yet.
    /// @return vaultId The new vault id.
    function createVault(
        PoolKey calldata key,
        PolicyLib.Policy calldata policy,
        address operator,
        uint256 bondAmount,
        uint160 sqrtPriceX96
    ) external nonReentrant returns (uint256 vaultId) {
        _validatePoolKey(key);
        PolicyLib.validate(policy, key.tickSpacing);
        if (operator == address(0)) revert ZeroAddress();

        PoolId id = key.toId();
        if (!pools[id].initialized) _initPool(key, id, sqrtPriceX96);

        vaultId = nextVaultId++;
        Vault storage v = _vaults[vaultId];
        v.key = key;
        v.owner = msg.sender;
        v.operator = operator;
        v.policy = policy;
        v.bond = bondAmount;
        v.epochStart = uint64(block.timestamp);

        if (bondAmount > 0) ERC20(bondToken).safeTransferFrom(msg.sender, address(this), bondAmount);
        emit VaultCreated(vaultId, id, msg.sender, operator, bondAmount);
    }

    /// @notice Replaces the vault policy. Only possible while the vault has no deposits (active or queued).
    /// @param vaultId The vault.
    /// @param policy The new policy.
    function setPolicy(uint256 vaultId, PolicyLib.Policy calldata policy) external {
        Vault storage v = _vault(vaultId);
        if (msg.sender != v.owner) revert OnlyOwner();
        if (v.totalShares != 0 || v.pending0 != 0 || v.pending1 != 0) revert PolicyLocked();
        PolicyLib.validate(policy, v.key.tickSpacing);
        v.policy = policy;
        emit PolicyUpdated(vaultId);
    }

    // ------------------------------------------------------------------
    // LP flows
    // ------------------------------------------------------------------

    /// @notice Queues a deposit; it becomes active (shares minted at TWAP) at the next `settleEpoch`.
    /// @param vaultId The vault.
    /// @param amount0 Amount of currency0.
    /// @param amount1 Amount of currency1.
    function deposit(uint256 vaultId, uint256 amount0, uint256 amount1) external nonReentrant {
        Vault storage v = _vault(vaultId);
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        _claim(vaultId, v, msg.sender);

        PendingDeposit storage pd = pendingDeposits[vaultId][msg.sender];
        pd.epoch = v.epoch;
        pd.amount0 += amount0;
        pd.amount1 += amount1;
        v.pending0 += amount0;
        v.pending1 += amount1;

        _pull(v.key.currency0, amount0);
        _pull(v.key.currency1, amount1);
        emit Deposited(vaultId, msg.sender, v.epoch, amount0, amount1);
    }

    /// @notice Cancels the caller's queued (not yet activated) deposit and returns the tokens.
    /// @param vaultId The vault.
    function cancelDeposit(uint256 vaultId) external nonReentrant {
        Vault storage v = _vault(vaultId);
        PendingDeposit memory pd = pendingDeposits[vaultId][msg.sender];
        if (pd.epoch != v.epoch || (pd.amount0 == 0 && pd.amount1 == 0)) revert NothingPending();

        delete pendingDeposits[vaultId][msg.sender];
        v.pending0 -= pd.amount0;
        v.pending1 -= pd.amount1;

        _push(v.key.currency0, msg.sender, pd.amount0);
        _push(v.key.currency1, msg.sender, pd.amount1);
        emit DepositCancelled(vaultId, msg.sender, pd.amount0, pd.amount1);
    }

    /// @notice Converts the caller's activated deposits into shares. Also done implicitly on deposit/withdraw.
    /// @param vaultId The vault.
    function claimShares(uint256 vaultId) external nonReentrant {
        _claim(vaultId, _vault(vaultId), msg.sender);
    }

    /// @notice Burns `shares` and returns the pro-rata part of the position and idle balances, in kind.
    /// @param vaultId The vault.
    /// @param shares Shares to burn.
    /// @param min0 Minimum currency0 out.
    /// @param min1 Minimum currency1 out.
    function withdraw(uint256 vaultId, uint256 shares, uint256 min0, uint256 min1)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Vault storage v = _vault(vaultId);
        _claim(vaultId, v, msg.sender);
        if (shares == 0) revert ZeroAmount();
        if (sharesOf[vaultId][msg.sender] < shares) revert InsufficientShares();

        uint256 total = v.totalShares;
        sharesOf[vaultId][msg.sender] -= shares;

        if (v.liquidity > 0) {
            uint128 liq = uint128(PerformanceLib.proRata(v.liquidity, shares, total));
            bytes memory res = poolManager.unlock(abi.encode(Action.WITHDRAW, vaultId, int24(0), int24(0), liq));
            (uint256 p0, uint256 p1, uint256 f0, uint256 f1) = abi.decode(res, (uint256, uint256, uint256, uint256));
            v.liquidity -= liq;
            v.idle0 += f0;
            v.idle1 += f1;
            amount0 = p0;
            amount1 = p1;
        }

        uint256 idleOut0 = PerformanceLib.proRata(v.idle0, shares, total);
        uint256 idleOut1 = PerformanceLib.proRata(v.idle1, shares, total);
        v.idle0 -= idleOut0;
        v.idle1 -= idleOut1;
        v.totalShares = total - shares;
        amount0 += idleOut0;
        amount1 += idleOut1;
        if (amount0 < min0 || amount1 < min1) revert Slippage();

        _push(v.key.currency0, msg.sender, amount0);
        _push(v.key.currency1, msg.sender, amount1);
        emit Withdrawn(vaultId, msg.sender, shares, amount0, amount1);
    }

    // ------------------------------------------------------------------
    // Operator
    // ------------------------------------------------------------------

    /// @notice Moves the vault's liquidity to [tickLower, tickUpper). Only the operator, within policy limits.
    /// @dev Removes all liquidity (fees go to idle), adds the max liquidity idle balances allow at spot,
    ///      leaves the rest idle. No swaps, so the vault's value at TWAP is unchanged.
    /// @param vaultId The vault.
    /// @param tickLower New lower tick (multiple of tick spacing).
    /// @param tickUpper New upper tick (multiple of tick spacing).
    function rebalance(uint256 vaultId, int24 tickLower, int24 tickUpper) external nonReentrant {
        Vault storage v = _vault(vaultId);
        if (msg.sender != v.operator) revert OnlyOperator();

        PoolId id = v.key.toId();
        (, int24 spotTick,,) = poolManager.getSlot0(id);
        int24 twapTick = _oracles[id].consult(spotTick, twapWindow);
        _checkRebalanceLimits(v, tickLower, tickUpper, spotTick, twapTick);

        v.lastRebalance = uint64(block.timestamp);
        v.rebalancesThisEpoch++;
        poolManager.unlock(abi.encode(Action.REBALANCE, vaultId, tickLower, tickUpper, uint128(0)));
        emit Rebalanced(vaultId, tickLower, tickUpper, v.liquidity, twapTick, spotTick);
    }

    // ------------------------------------------------------------------
    // Epochs
    // ------------------------------------------------------------------

    /// @notice Closes the current epoch: values the vault at TWAP and activates queued deposits. Callable by anyone.
    /// @dev M1: no benchmark/slash yet. Order (final): valuation -> slash -> perf fee -> activate deposits.
    /// @param vaultId The vault.
    function settleEpoch(uint256 vaultId) external nonReentrant {
        Vault storage v = _vault(vaultId);
        if (block.timestamp < uint256(v.epochStart) + v.policy.epochLength) revert EpochNotOver();

        PoolId id = v.key.toId();
        (, int24 spotTick,,) = poolManager.getSlot0(id);
        int24 twapTick = _oracles[id].consult(spotTick, twapWindow);
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(twapTick);
        bool bond0 = pools[id].bondIsToken0;

        uint256 vaultValue = _vaultValue(vaultId, v, id, sqrtTwap, bond0);
        uint256 depositValue = PerformanceLib.valueInBond(v.pending0, v.pending1, sqrtTwap, bond0, false);
        uint256 totalShares = v.totalShares;
        uint256 minted = PerformanceLib.sharesForDeposit(depositValue, totalShares, vaultValue);

        uint64 epoch = v.epoch;
        epochRates[vaultId][epoch] = EpochRate({
            sqrtPriceX96: sqrtTwap,
            shareNum: totalShares + PerformanceLib.VIRTUAL_SHARES,
            valueDen: vaultValue + PerformanceLib.VIRTUAL_ASSETS
        });

        v.totalShares = totalShares + minted;
        v.idle0 += v.pending0;
        v.idle1 += v.pending1;
        v.pending0 = 0;
        v.pending1 = 0;
        v.epoch = epoch + 1;
        v.epochStart = uint64(block.timestamp);
        v.rebalancesThisEpoch = 0;

        emit EpochSettled(vaultId, epoch, twapTick, vaultValue, totalShares, depositValue, minted);
    }

    // ------------------------------------------------------------------
    // PoolManager callbacks
    // ------------------------------------------------------------------

    /// @notice PoolManager unlock callback; only reachable through this contract's own `unlock` calls.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, uint256 vaultId, int24 tickLower, int24 tickUpper, uint128 liq) =
            abi.decode(data, (Action, uint256, int24, int24, uint128));
        if (action == Action.WITHDRAW) return _unlockWithdraw(vaultId, liq);
        _unlockRebalance(vaultId, tickLower, tickUpper);
        return "";
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert OnlyAvalPools();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert OnlyHookLiquidity();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert OnlyHookLiquidity();
    }

    /// @dev O(1) in the number of vaults: one oracle update + one bounded TWAP read.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        TwapLib.Oracle storage oracle = _oracles[id];
        oracle.update(tick, twapGranularity);
        uint24 fee = _dynamicFee(oracle, tick);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Full vault state.
    function getVault(uint256 vaultId) external view returns (Vault memory) {
        return _vaults[vaultId];
    }

    /// @notice TWAP tick of a pool over `twapWindow`. Reverts if not warm.
    function getTwapTick(PoolId id) external view returns (int24) {
        (, int24 spotTick,,) = poolManager.getSlot0(id);
        return _oracles[id].consult(spotTick, twapWindow);
    }

    /// @notice True if the pool's oracle covers `twapWindow`.
    function isTwapWarm(PoolId id) external view returns (bool) {
        return _oracles[id].isWarm(twapWindow);
    }

    /// @notice Active vault value (position + idle + uncollected fees) at TWAP, in bond token. Excludes queued deposits.
    function getVaultValue(uint256 vaultId) external view returns (uint256) {
        Vault storage v = _vault(vaultId);
        PoolId id = v.key.toId();
        (, int24 spotTick,,) = poolManager.getSlot0(id);
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(_oracles[id].consult(spotTick, twapWindow));
        return _vaultValue(vaultId, v, id, sqrtTwap, pools[id].bondIsToken0);
    }

    /// @notice Current dynamic fee (pips) the pool would charge.
    function currentFee(PoolId id) external view returns (uint24) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        return _dynamicFee(_oracles[id], tick);
    }

    // ------------------------------------------------------------------
    // Internal: liquidity operations (inside unlock)
    // ------------------------------------------------------------------

    function _unlockWithdraw(uint256 vaultId, uint128 liq) internal returns (bytes memory) {
        Vault storage v = _vaults[vaultId];
        (BalanceDelta delta, BalanceDelta fees) = _modify(vaultId, v, v.tickLower, v.tickUpper, -int256(uint256(liq)));
        _settleDeltas(v.key, delta.amount0(), delta.amount1());
        // callerDelta = principal + fees, both non-negative when removing.
        uint256 f0 = _toUint(fees.amount0());
        uint256 f1 = _toUint(fees.amount1());
        uint256 p0 = _toUint(delta.amount0()) - f0;
        uint256 p1 = _toUint(delta.amount1()) - f1;
        return abi.encode(p0, p1, f0, f1);
    }

    function _unlockRebalance(uint256 vaultId, int24 tickLower, int24 tickUpper) internal {
        Vault storage v = _vaults[vaultId];
        int256 net0;
        int256 net1;

        if (v.liquidity > 0) {
            (BalanceDelta out,) = _modify(vaultId, v, v.tickLower, v.tickUpper, -int256(uint256(v.liquidity)));
            net0 = out.amount0();
            net1 = out.amount1();
            v.idle0 += _toUint(out.amount0());
            v.idle1 += _toUint(out.amount1());
        }

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(v.key.toId());
        // 1-wei buffer so PoolManager's round-up never exceeds idle balances.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            v.idle0 > 0 ? v.idle0 - 1 : 0,
            v.idle1 > 0 ? v.idle1 - 1 : 0
        );

        if (liquidity > 0) {
            (BalanceDelta add,) = _modify(vaultId, v, tickLower, tickUpper, int256(uint256(liquidity)));
            net0 += add.amount0();
            net1 += add.amount1();
            v.idle0 -= _toUint(-add.amount0());
            v.idle1 -= _toUint(-add.amount1());
        }

        v.tickLower = tickLower;
        v.tickUpper = tickUpper;
        v.liquidity = liquidity;
        _settleDeltas(v.key, net0, net1);
    }

    function _modify(uint256 vaultId, Vault storage v, int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
        returns (BalanceDelta delta, BalanceDelta fees)
    {
        (delta, fees) = poolManager.modifyLiquidity(
            v.key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(vaultId)
            }),
            ""
        );
    }

    /// @dev Positive delta: PoolManager owes the hook -> take. Negative: hook owes -> settle from own balance.
    function _settleDeltas(PoolKey memory key, int256 delta0, int256 delta1) internal {
        if (delta0 > 0) key.currency0.take(poolManager, address(this), uint256(delta0), false);
        else if (delta0 < 0) key.currency0.settle(poolManager, address(this), uint256(-delta0), false);
        if (delta1 > 0) key.currency1.take(poolManager, address(this), uint256(delta1), false);
        else if (delta1 < 0) key.currency1.settle(poolManager, address(this), uint256(-delta1), false);
    }

    // ------------------------------------------------------------------
    // Internal: helpers
    // ------------------------------------------------------------------

    function _vault(uint256 vaultId) internal view returns (Vault storage v) {
        v = _vaults[vaultId];
        if (v.owner == address(0)) revert VaultNotFound();
    }

    function _validatePoolKey(PoolKey calldata key) internal view {
        if (address(key.hooks) != address(this)) revert InvalidPoolKey();
        if (key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != TICK_SPACING) revert InvalidPoolKey();
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        if (t0 >= t1) revert InvalidPoolKey();
        if (!isAllowedToken[t0] || !isAllowedToken[t1]) revert TokenNotAllowed();
        if ((t0 == bondToken) == (t1 == bondToken)) revert TokenNotAllowed();
    }

    function _initPool(PoolKey calldata key, PoolId id, uint160 sqrtPriceX96) internal {
        // noSelfCall: our own beforeInitialize is skipped.
        poolManager.initialize(key, sqrtPriceX96);
        pools[id] = PoolInfo({initialized: true, bondIsToken0: Currency.unwrap(key.currency0) == bondToken});
        _oracles[id].initialize();
    }

    /// @dev Converts the user's activated pending deposit into shares at that epoch's rate.
    function _claim(uint256 vaultId, Vault storage v, address user) internal {
        PendingDeposit memory pd = pendingDeposits[vaultId][user];
        if (pd.epoch >= v.epoch || (pd.amount0 == 0 && pd.amount1 == 0)) return;

        EpochRate memory rate = epochRates[vaultId][pd.epoch];
        bool bond0 = pools[v.key.toId()].bondIsToken0;
        uint256 value = PerformanceLib.valueInBond(pd.amount0, pd.amount1, rate.sqrtPriceX96, bond0, false);
        uint256 shares = FullMath.mulDiv(value, rate.shareNum, rate.valueDen);

        delete pendingDeposits[vaultId][user];
        sharesOf[vaultId][user] += shares;
        emit SharesClaimed(vaultId, user, pd.epoch, shares);
    }

    function _checkRebalanceLimits(Vault storage v, int24 tickLower, int24 tickUpper, int24 spotTick, int24 twap)
        internal
        view
    {
        PolicyLib.Policy memory p = v.policy;
        if (v.lastRebalance != 0 && block.timestamp < uint256(v.lastRebalance) + p.cooldown) revert CooldownActive();
        if (v.rebalancesThisEpoch >= p.maxRebalancesPerEpoch) revert TooManyRebalances();

        int24 spacing = v.key.tickSpacing;
        if (
            tickLower >= tickUpper || tickLower % spacing != 0 || tickUpper % spacing != 0
                || tickLower < TickMath.minUsableTick(spacing) || tickUpper > TickMath.maxUsableTick(spacing)
        ) revert InvalidRange();

        uint256 width = uint256(int256(tickUpper) - int256(tickLower));
        if (width < p.minWidthTicks || width > p.maxWidthTicks) revert InvalidWidth();

        int256 center = (int256(tickLower) + int256(tickUpper)) / 2;
        if (_absDiff(center, twap) > p.maxRangeDeviationTicks) revert RangeTooFarFromTwap();
        if (_absDiff(spotTick, twap) > p.maxSpotTwapDeviationBps) revert SpotTooFarFromTwap();
    }

    function _vaultValue(uint256 vaultId, Vault storage v, PoolId id, uint160 sqrtTwap, bool bond0)
        internal
        view
        returns (uint256)
    {
        (uint256 a0, uint256 a1) = PerformanceLib.amountsForLiquidity(
            sqrtTwap, TickMath.getSqrtPriceAtTick(v.tickLower), TickMath.getSqrtPriceAtTick(v.tickUpper), v.liquidity
        );
        (uint256 f0, uint256 f1) = _uncollectedFees(vaultId, v, id);
        return PerformanceLib.valueInBond(a0 + f0 + v.idle0, a1 + f1 + v.idle1, sqrtTwap, bond0, true);
    }

    function _uncollectedFees(uint256 vaultId, Vault storage v, PoolId id)
        internal
        view
        returns (uint256 f0, uint256 f1)
    {
        if (v.liquidity == 0) return (0, 0);
        (uint128 liq, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(id, address(this), v.tickLower, v.tickUpper, bytes32(vaultId));
        (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(id, v.tickLower, v.tickUpper);
        unchecked {
            f0 = FullMath.mulDiv(inside0 - last0, liq, FixedPoint128.Q128);
            f1 = FullMath.mulDiv(inside1 - last1, liq, FixedPoint128.Q128);
        }
    }

    function _dynamicFee(TwapLib.Oracle storage oracle, int24 tick) internal view returns (uint24) {
        (bool ok, int24 twap) = oracle.tryConsult(tick, twapWindow);
        if (!ok) return BASE_FEE;
        uint256 dev = _absDiff(tick, twap);
        if (dev <= FREE_DEVIATION_TICKS) return BASE_FEE;
        uint256 fee = BASE_FEE + (dev - FREE_DEVIATION_TICKS) * FEE_SLOPE_PER_TICK;
        return fee > MAX_FEE ? MAX_FEE : uint24(fee);
    }

    function _pull(Currency currency, uint256 amount) internal {
        if (amount > 0) ERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
    }

    function _push(Currency currency, address to, uint256 amount) internal {
        if (amount > 0) ERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }

    function _toUint(int128 x) internal pure returns (uint256) {
        return x > 0 ? uint256(uint128(x)) : 0;
    }
}
