// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";

/**
 * @title DeploySendtokenAdapter
 * @notice Template for deploying any L1 adapter for a specific L2.
 * @dev Replace Sendtoken with the specific L2 name (e.g., Arbitrum, Optimism).
 */
contract DeploySendtokenAdapter is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get addresses specific to the current network
        // These would be specific to the L2 you're targeting
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL1Address(chainId, "cctpTokenMessenger");

        // Other addresses specific to this L2 protocol
        // address specificBridgeAddress = getL1Address(chainId, "specificBridgeAddressKey");

        console.log("Deploying Sendtoken Adapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("WETH: %s", weth);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);
        // console.log("Specific Bridge Address: %s", specificBridgeAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Example adapter deployment (adjust for your specific adapter)
        // Sendtoken_Adapter adapter = new Sendtoken_Adapter(
        //     specificBridgeAddress,
        //     weth,
        //     usdc,
        //     cctpTokenMessenger
        // );
        // console.log("Sendtoken_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }
}
