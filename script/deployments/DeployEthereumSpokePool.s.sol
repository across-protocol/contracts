// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Ethereum_SpokePool } from "../../contracts/Ethereum_SpokePool.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";

/**
 * @title DeployEthereumSpokePool
 * @notice Deploys the Ethereum Spoke Pool contract.
 * @dev Migration of 007_deploy_ethereum_spokepool.ts script to Foundry.
 */
contract DeployEthereumSpokePool is Script, ChainUtils {
    // Constants from consts.ts
    uint32 constant QUOTE_TIME_BUFFER = 3600;
    uint32 constant FILL_DEADLINE_BUFFER = 21600; // 6 hours

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // The hub pool address should be provided as an environment variable
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        // Get addresses
        address weth = getWETH(chainId);

        console.log("Deploying Ethereum_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("WETH: %s", weth);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        Ethereum_SpokePool spokePoolImplementation = new Ethereum_SpokePool(
            weth,
            QUOTE_TIME_BUFFER,
            FILL_DEADLINE_BUFFER
        );
        console.log("Ethereum_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxyn        ProxyAdmin proxyAdmin = new ProxyAdmin();n        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));n        n        // Create initialization data for the proxyn        bytes memory initData = abi.encodeWithSelector(n            Ethereum_SpokePool.initialize.selector,n            INITIAL_DEPOSIT_ID,  // Initial deposit IDn            hubPoolAddress,      // Set hub pool as cross domain adminn            hubPoolAddress       // Set hub pool as withdrawal recipientn        );n        n        // Deploy the proxy pointing to the implementation with initialization datan        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(n            address(spokePoolImplementation),n            address(proxyAdmin),     // Admin of the proxyn            initDatan        );n        console.log("Ethereum_SpokePool proxy deployed at: %s", address(proxy));n        n        // Transfer ProxyAdmin ownership to the deployern        proxyAdmin.transferOwnership(deployer);n        console.log("ProxyAdmin ownership transferred to: %s", deployer);        // Note: In a real deployment, you would:
        // 1. Deploy a proxy pointing to this implementation
        // 2. Call initialize() on the proxy with:
        //    - Initial deposit ID: 1_000_000 (to avoid duplicate IDs with deprecated spoke pool)
        //    - Withdrawal Recipient: hubPoolAddress

        // For example:
        // EthereumSpokePoolProxy proxy = new EthereumSpokePoolProxy(address(spokePoolImplementation));
        // Ethereum_SpokePool(address(proxy)).initialize(
        //     1_000_000,
        //     hubPoolAddress
        // );
        // console.log("Ethereum_SpokePool proxy deployed at: %s", address(proxy));

        vm.stopBroadcast();
    }
}
