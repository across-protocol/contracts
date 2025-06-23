// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title DeployLiskSpokePool
 * @notice Template for deploying any L2 SpokePool.
 * @dev Replace Lisk with the specific L2 name (e.g., Arbitrum, Optimism).
 */
contract DeployLiskSpokePool is Script, ChainUtils {
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

        // Get L2 addresses specific to this chain
        address wrappedNativeToken = getLiskWrappedNative(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL2Address(chainId, "cctpTokenMessenger");

        // Other chain-specific addresses would be included here
        // address specificBridgeAddress = getL2Address(chainId, "bridgeAddressKey");

        console.log("Deploying Lisk_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("Wrapped Native Token: %s", wrappedNativeToken);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);
        // console.log("Specific Bridge Address: %s", specificBridgeAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        // Lisk_SpokePool spokePoolImplementation = new Lisk_SpokePool(
        //     wrappedNativeToken,
        //     QUOTE_TIME_BUFFER,
        //     FILL_DEADLINE_BUFFER,
        //     IERC20(usdc),
        //     ITokenMessenger(cctpTokenMessenger)
        // );
        // console.log("Lisk_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxyn        ProxyAdmin proxyAdmin = new ProxyAdmin();n        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));n        n        // Create initialization data for the proxyn        bytes memory initData = abi.encodeWithSelector(n            Lisk_SpokePool.initialize.selector,n            INITIAL_DEPOSIT_ID,  // Initial deposit IDn            hubPoolAddress,      // Set hub pool as cross domain adminn            hubPoolAddress       // Set hub pool as withdrawal recipientn        );n        n        // Deploy the proxy pointing to the implementation with initialization datan        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(n            address(spokePoolImplementation),n            address(proxyAdmin),     // Admin of the proxyn            initDatan        );n        console.log("Lisk_SpokePool proxy deployed at: %s", address(proxy));n        n        // Transfer ProxyAdmin ownership to the deployern        proxyAdmin.transferOwnership(deployer);n        console.log("ProxyAdmin ownership transferred to: %s", deployer);        // Note: In a real deployment, you would:
        // 1. Deploy a proxy pointing to this implementation
        // 2. Call initialize() on the proxy with appropriate parameters
        //    - Initial deposit ID: 1_000_000 (to avoid duplicate IDs with deprecated spoke pool)
        //    - Other chain-specific parameters like bridge addresses, etc.

        vm.stopBroadcast();
    }

    // Helper function to get wrapped native token for the L2 chain
    function getLiskWrappedNative(uint256 chainId) internal pure returns (address) {
        // Example implementation
        if (chainId == ARBITRUM) return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        if (chainId == OPTIMISM) return 0x4200000000000000000000000000000000000006;
        revert(string.concat("No wrapped native token found for chainId ", vm.toString(chainId)));
    }
}
