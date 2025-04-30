// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Optimism_SpokePool } from "../../contracts/Optimism_SpokePool.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title DeployOptimismSpokePool
 * @notice Deploys the Optimism Spoke Pool contract.
 * @dev This is a migration of the original 003_deploy_optimism_spokepool.ts script to Foundry.
 */
contract DeployOptimismSpokePool is Script, Test, ChainUtils {
    // Constants
    uint32 constant INITIAL_DEPOSIT_ID = 1_000_000; // To avoid duplicate IDs with deprecated spoke pool

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // These values would typically come from deployments or configuration
        address hubPool = vm.envAddress("HUB_POOL_ADDRESS");
        address crossDomainMessenger;
        address l2StandardBridge;
        address token = getWETH(chainId); // WETH on the current chain

        // Sets these values based on the current chain
        if (chainId == OPTIMISM) {
            crossDomainMessenger = 0x4200000000000000000000000000000000000007;
            l2StandardBridge = 0x4200000000000000000000000000000000000010;
        } else if (chainId == OPTIMISM_SEPOLIA) {
            crossDomainMessenger = 0x4200000000000000000000000000000000000007;
            l2StandardBridge = 0x4200000000000000000000000000000000000010;
        } else {
            revert("Unsupported chain for Optimism_SpokePool deployment");
        }

        console.log("Deploying Optimism_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPool);
        console.log("CrossDomainMessenger: %s", crossDomainMessenger);
        console.log("L2StandardBridge: %s", l2StandardBridge);
        console.log("Token: %s", token);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation - note the constructor parameters have changed in the current version
        Optimism_SpokePool spokePoolImplementation = new Optimism_SpokePool(
            token, // L2 wrapped ETH token
            3600, // Quote time buffer (1 hour)
            21600, // Fill deadline buffer (6 hours)
            IERC20(0x7F5c764cBc14f9669B88837ca1490cCa17c31607), // L2 USDC on Optimism
            ITokenMessenger(0x2B4069517957735bE00ceE0fadAE88a26365528f) // CCTP Token Messenger on Optimism
        );
        console.log("Optimism_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxy
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));

        // Create initialization data for the proxy
        bytes memory initData = abi.encodeWithSelector(
            Optimism_SpokePool.initialize.selector,
            INITIAL_DEPOSIT_ID, // Initial deposit ID
            hubPool, // Set hub pool as cross domain admin
            hubPool // Set hub pool as withdrawal recipient
        );

        // Deploy the proxy pointing to the implementation with initialization data
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(spokePoolImplementation),
            address(proxyAdmin), // Admin of the proxy
            initData
        );
        console.log("Optimism_SpokePool proxy deployed at: %s", address(proxy));

        // Transfer ProxyAdmin ownership to the deployer
        proxyAdmin.transferOwnership(deployer);
        console.log("ProxyAdmin ownership transferred to: %s", deployer);

        vm.stopBroadcast();
    }
}
