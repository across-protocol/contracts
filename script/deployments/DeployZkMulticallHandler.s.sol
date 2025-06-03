// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";

/**
 * @title DeployZkMulticallHandler
 * @notice Template for deploying utility contracts like Multicall, ERC1155, etc.
 * @dev Replace ZkMulticallHandler with the specific name (e.g., Multicall3, ERC1155).
 */
contract DeployZkMulticallHandler is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get any addresses needed for this utility contract
        // address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        console.log("Deploying ZkMulticallHandler on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        // console.log("Hub Pool: %s", hubPoolAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Example utility contract deployment
        // ZkMulticallHandler utility = new ZkMulticallHandler(
        //     // Constructor parameters if any
        // );
        // console.log("ZkMulticallHandler deployed at: %s", address(utility));

        vm.stopBroadcast();
    }
}
