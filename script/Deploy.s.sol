// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Deployers} from "test/utils/Deployers.sol";
import {AvalHook} from "src/AvalHook.sol";
import {PolicyLib} from "src/libraries/PolicyLib.sol";

/// @notice Deploys mocks (mUSDC, mWETH), the AvalHook at a mined address, the mWETH/mUSDC pool and two demo
///         vaults (agent A honest, agent B lazy/malicious), seeds deposits and writes deployments/<chainId>.json.
/// @dev On anvil (31337) the v4 artifacts are etched locally; elsewhere hookmate's canonical addresses are used
///      (verify them against the official Uniswap deployments page before a testnet broadcast).
///      Env (all optional): AGENT_A, AGENT_B, TWAP_WINDOW (s), EPOCH_LENGTH (s), ETH_PRICE (USDC).
contract Deploy is Script, Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BOND = 10_000e6;
    uint256 internal constant SEED_USDC = 30_000e6;
    uint256 internal constant SEED_WETH = 10 ether;

    struct Config {
        address deployer;
        address agentA;
        address agentB;
        uint32 twapWindow;
        uint32 epochLength;
        uint256 ethPrice;
    }

    function run() external {
        Config memory cfg = _config();

        vm.startBroadcast();
        deployArtifacts();

        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        usdc.mint(cfg.deployer, 10_000_000e6);
        weth.mint(cfg.deployer, 10_000 ether);

        AvalHook hook = _deployHook(address(usdc), address(weth), cfg.twapWindow);
        PoolKey memory key = _poolKey(address(usdc), address(weth), address(hook));
        uint160 sqrtPrice = _sqrtPrice(address(usdc) < address(weth), cfg.ethPrice);

        usdc.approve(address(hook), type(uint256).max);
        weth.approve(address(hook), type(uint256).max);
        usdc.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);

        PolicyLib.Policy memory policy = _demoPolicy(cfg.epochLength);
        uint256 vaultA = hook.createVault(key, policy, cfg.agentA, BOND, sqrtPrice);
        uint256 vaultB = hook.createVault(key, policy, cfg.agentB, BOND, sqrtPrice);
        _seed(hook, vaultA, address(usdc) < address(weth));
        _seed(hook, vaultB, address(usdc) < address(weth));
        vm.stopBroadcast();

        _writeDeployment(cfg, address(usdc), address(weth), hook, key, vaultA, vaultB);
    }

    // ------------------------------------------------------------------

    function _config() internal returns (Config memory cfg) {
        address[] memory wallets = vm.getWallets();
        cfg.deployer = wallets.length > 0 ? wallets[0] : msg.sender;
        cfg.agentA = vm.envOr("AGENT_A", address(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)); // anvil #1
        cfg.agentB = vm.envOr("AGENT_B", address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC)); // anvil #2
        cfg.twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(120)));
        cfg.epochLength = uint32(vm.envOr("EPOCH_LENGTH", uint256(300)));
        cfg.ethPrice = vm.envOr("ETH_PRICE", uint256(3000));
    }

    function _deployHook(address usdc, address weth, uint32 twapWindow) internal returns (AvalHook hook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        address[] memory allowed = new address[](1);
        allowed[0] = weth;
        bytes memory args = abi.encode(poolManager, usdc, allowed, twapWindow);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, flags, type(AvalHook).creationCode, args);
        hook = new AvalHook{salt: salt}(poolManager, usdc, allowed, twapWindow);
        require(address(hook) == expected, "Deploy: hook address mismatch");
    }

    function _poolKey(address usdc, address weth, address hook) internal pure returns (PoolKey memory) {
        (address t0, address t1) = usdc < weth ? (usdc, weth) : (weth, usdc);
        return PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    /// @dev Raw price of token1 in token0 units for an ETH price in whole USDC (6 vs 18 decimals).
    function _sqrtPrice(bool usdcIs0, uint256 ethPrice) internal pure returns (uint160) {
        (uint256 num, uint256 den) = usdcIs0 ? (uint256(1e12), ethPrice) : (ethPrice, uint256(1e12));
        return uint160(FixedPointMathLib.sqrt((num << 192) / den));
    }

    function _demoPolicy(uint32 epochLength) internal pure returns (PolicyLib.Policy memory) {
        return PolicyLib.Policy({
            maxRangeDeviationTicks: 600,
            maxSpotTwapDeviationBps: 100,
            cooldown: 30,
            maxRebalancesPerEpoch: 5,
            minWidthTicks: 120,
            maxWidthTicks: 12_000,
            epochLength: epochLength
        });
    }

    function _seed(AvalHook hook, uint256 vaultId, bool usdcIs0) internal {
        (uint256 a0, uint256 a1) = usdcIs0 ? (SEED_USDC, SEED_WETH) : (SEED_WETH, SEED_USDC);
        hook.deposit(vaultId, a0, a1);
    }

    function _writeDeployment(
        Config memory cfg,
        address usdc,
        address weth,
        AvalHook hook,
        PoolKey memory key,
        uint256 vaultA,
        uint256 vaultB
    ) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "poolManager", address(poolManager));
        vm.serializeAddress(o, "swapRouter", address(swapRouter));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "mUSDC", usdc);
        vm.serializeAddress(o, "mWETH", weth);
        vm.serializeAddress(o, "currency0", Currency.unwrap(key.currency0));
        vm.serializeAddress(o, "currency1", Currency.unwrap(key.currency1));
        vm.serializeBytes32(o, "poolId", PoolId.unwrap(key.toId()));
        vm.serializeAddress(o, "agentA", cfg.agentA);
        vm.serializeAddress(o, "agentB", cfg.agentB);
        vm.serializeUint(o, "vaultA", vaultA);
        vm.serializeUint(o, "twapWindow", cfg.twapWindow);
        vm.serializeUint(o, "epochLength", cfg.epochLength);
        string memory json = vm.serializeUint(o, "vaultB", vaultB);
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);

        console2.log("AvalHook:", address(hook));
        console2.log("Vault A (honest):", vaultA, "operator", cfg.agentA);
        console2.log("Vault B (lazy):  ", vaultB, "operator", cfg.agentB);
        console2.log("Deployment written to", path);
    }

    function _etch(address target, bytes memory bytecode) internal override {
        require(block.chainid == 31337, "Deploy: etch only on anvil");
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(target), '","', vm.toString(bytecode), '"]'));
    }
}
