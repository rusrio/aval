// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {AvalHook} from "./AvalHook.sol";
import {PolicyLib} from "./libraries/PolicyLib.sol";
import {TwapLib} from "./libraries/TwapLib.sol";
import {PerformanceLib} from "./libraries/PerformanceLib.sol";

/// @title AvalLens
/// @notice Read-only views over AvalHook state for the agent, the dashboard and tests. Kept out of the hook so the
///         hook stays under the 24 KB code size limit; it reads the hook's storage through `extsload`.
/// @dev Decodes the hook's storage layout by hand. Slot numbers and packing must match
///      `forge inspect AvalHook storageLayout`; any change to AvalHook state variables or the Vault / Oracle /
///      PoolInfo structs must be mirrored here (covered by test/unit/AvalLens.t.sol).
contract AvalLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant POOLS_SLOT = 2;
    uint256 private constant ORACLES_SLOT = 3;
    uint256 private constant VAULTS_SLOT = 5;
    uint256 private constant VAULT_SLOTS = 19;
    uint256 private constant ORACLE_SLOTS = 1 + TwapLib.CARDINALITY;

    AvalHook public immutable hook;
    IPoolManager public immutable poolManager;

    error VaultNotFound();

    /// @param _hook The AvalHook to read.
    constructor(AvalHook _hook) {
        hook = _hook;
        poolManager = _hook.poolManager();
    }

    // ------------------------------------------------------------------
    // Raw state
    // ------------------------------------------------------------------

    /// @notice Full vault state. Reverts with `VaultNotFound` for unknown ids.
    function getVault(uint256 vaultId) public view returns (AvalHook.Vault memory v) {
        bytes32[] memory s = hook.extsload(keccak256(abi.encode(vaultId, VAULTS_SLOT)), VAULT_SLOTS);
        v.key = _decodeKey(s);
        v.owner = address(uint160(uint256(s[3])));
        if (v.owner == address(0)) revert VaultNotFound();
        v.operator = address(uint160(uint256(s[4])));
        v.policy = _decodePolicy(uint256(s[5]));

        uint256 w = uint256(s[6]);
        v.tickLower = int24(uint24(w));
        v.tickUpper = int24(uint24(w >> 24));
        v.liquidity = uint128(w >> 48);

        v.idle0 = uint256(s[7]);
        v.idle1 = uint256(s[8]);
        v.totalShares = uint256(s[9]);
        v.pending0 = uint256(s[10]);
        v.pending1 = uint256(s[11]);
        v.bond = uint256(s[12]);
        v.bondWithdrawalAmount = uint256(s[13]);

        w = uint256(s[14]);
        v.bondWithdrawalEpoch = uint64(w);
        v.epoch = uint64(w >> 64);
        v.epochStart = uint64(w >> 128);
        v.lastRebalance = uint64(w >> 192);

        w = uint256(s[15]);
        v.rebalancesThisEpoch = uint16(w);
        v.safeMode = (w >> 16) & 1 == 1;

        v.benchValue0 = uint256(s[16]);
        v.benchShares0 = uint256(s[17]);
        v.benchSqrtPrice0 = uint160(uint256(s[18]));
    }

    /// @notice The pool's TWAP oracle (accumulator and checkpoint ring buffer).
    function getOracle(PoolId id) public view returns (TwapLib.Oracle memory o) {
        bytes32[] memory s = hook.extsload(keccak256(abi.encode(id, ORACLES_SLOT)), ORACLE_SLOTS);
        uint256 w = uint256(s[0]);
        o.lastTimestamp = uint32(w);
        o.tickCumulative = int64(uint64(w >> 32));
        o.index = uint8(w >> 96);
        o.count = uint8(w >> 104);
        for (uint256 i; i < TwapLib.CARDINALITY; ++i) {
            w = uint256(s[1 + i]);
            o.checkpoints[i] = TwapLib.Checkpoint({timestamp: uint32(w), tickCumulative: int64(uint64(w >> 32))});
        }
    }

    // ------------------------------------------------------------------
    // TWAP & fee
    // ------------------------------------------------------------------

    /// @notice True if the pool's oracle covers the hook's TWAP window.
    function isTwapWarm(PoolId id) external view returns (bool ok) {
        (ok,) = _tryTwap(id);
    }

    /// @notice TWAP tick of a pool over the hook's window. Reverts with `TwapLib.TwapNotWarm` if not warm.
    function getTwapTick(PoolId id) public view returns (int24 tick) {
        bool ok;
        (ok, tick) = _tryTwap(id);
        if (!ok) revert TwapLib.TwapNotWarm();
    }

    /// @notice Dynamic fee (pips) the pool would charge now; mirrors the hook's `beforeSwap`.
    function currentFee(PoolId id) external view returns (uint24) {
        (bool ok, int24 twap) = _tryTwap(id);
        uint24 base = hook.BASE_FEE();
        if (!ok) return base;
        (, int24 tick,,) = poolManager.getSlot0(id);
        uint256 dev = _absDiff(tick, twap);
        uint256 free = hook.FREE_DEVIATION_TICKS();
        if (dev <= free) return base;
        uint256 fee = base + (dev - free) * hook.FEE_SLOPE_PER_TICK();
        uint24 maxFee = hook.MAX_FEE();
        return fee > maxFee ? maxFee : uint24(fee);
    }

    // ------------------------------------------------------------------
    // Valuation
    // ------------------------------------------------------------------

    /// @notice Active vault value (position + idle + uncollected fees) at TWAP, in bond token. Excludes queued deposits.
    function getVaultValue(uint256 vaultId) external view returns (uint256 value) {
        (, value) = getPerformance(vaultId);
    }

    /// @notice Benchmark and vault value at TWAP, both in bond token and for the current total shares.
    /// @return benchmark Value a passive full-range position would have now (0 if the epoch started empty).
    /// @return value Active vault value (excludes queued deposits); same as the hook's settlement valuation.
    function getPerformance(uint256 vaultId) public view returns (uint256 benchmark, uint256 value) {
        AvalHook.Vault memory v = getVault(vaultId);
        PoolId id = v.key.toId();
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(getTwapTick(id));
        bool bond0 = _bondIsToken0(id);
        value = _vaultValue(vaultId, v, id, sqrtTwap, bond0);
        if (v.benchShares0 != 0 && v.totalShares != 0) {
            benchmark = PerformanceLib.benchmarkValue(
                v.benchValue0, v.benchShares0, v.totalShares, v.benchSqrtPrice0, sqrtTwap, bond0
            );
        }
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _tryTwap(PoolId id) internal view returns (bool, int24) {
        (, int24 tick,,) = poolManager.getSlot0(id);
        return TwapLib.tryConsultMemory(getOracle(id), tick, hook.twapWindow());
    }

    function _bondIsToken0(PoolId id) internal view returns (bool) {
        bytes32[] memory s = hook.extsload(keccak256(abi.encode(id, POOLS_SLOT)), 1);
        return (uint256(s[0]) >> 8) & 1 == 1;
    }

    /// @dev Mirrors AvalHook._vaultValue: position at TWAP + uncollected fees + idle, rounded up.
    function _vaultValue(uint256 vaultId, AvalHook.Vault memory v, PoolId id, uint160 sqrtTwap, bool bond0)
        internal
        view
        returns (uint256)
    {
        (uint256 a0, uint256 a1) = PerformanceLib.amountsForLiquidity(
            sqrtTwap, TickMath.getSqrtPriceAtTick(v.tickLower), TickMath.getSqrtPriceAtTick(v.tickUpper), v.liquidity
        );
        if (v.liquidity > 0) {
            (uint128 liq, uint256 last0, uint256 last1) =
                poolManager.getPositionInfo(id, address(hook), v.tickLower, v.tickUpper, bytes32(vaultId));
            (uint256 inside0, uint256 inside1) = poolManager.getFeeGrowthInside(id, v.tickLower, v.tickUpper);
            unchecked {
                a0 += FullMath.mulDiv(inside0 - last0, liq, FixedPoint128.Q128);
                a1 += FullMath.mulDiv(inside1 - last1, liq, FixedPoint128.Q128);
            }
        }
        return PerformanceLib.valueInBond(a0 + v.idle0, a1 + v.idle1, sqrtTwap, bond0, true);
    }

    function _decodeKey(bytes32[] memory s) internal pure returns (PoolKey memory) {
        uint256 w = uint256(s[1]);
        return PoolKey({
            currency0: Currency.wrap(address(uint160(uint256(s[0])))),
            currency1: Currency.wrap(address(uint160(w))),
            fee: uint24(w >> 160),
            tickSpacing: int24(uint24(w >> 184)),
            hooks: IHooks(address(uint160(uint256(s[2]))))
        });
    }

    function _decodePolicy(uint256 w) internal pure returns (PolicyLib.Policy memory) {
        return PolicyLib.Policy({
            maxRangeDeviationTicks: uint24(w),
            maxSpotTwapDeviationBps: uint24(w >> 24),
            cooldown: uint32(w >> 48),
            maxRebalancesPerEpoch: uint16(w >> 80),
            minWidthTicks: uint24(w >> 96),
            maxWidthTicks: uint24(w >> 120),
            epochLength: uint32(w >> 144),
            toleranceBps: uint16(w >> 176),
            slashRatioBps: uint16(w >> 192)
        });
    }

    function _absDiff(int256 a, int256 b) internal pure returns (uint256) {
        return a >= b ? uint256(a - b) : uint256(b - a);
    }
}
