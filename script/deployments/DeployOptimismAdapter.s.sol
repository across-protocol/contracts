// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Optimism_Adapter } from "../../contracts/chain-adapters/Optimism_Adapter.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

/**
 * @title DeployOptimismAdapter
 * @notice Deploys the Optimism adapter contract.
 * @dev This is a migration of the original 002_deploy_optimism_adapter.ts script to Foundry.
 */
contract DeployOptimismAdapter is Script, Test, ChainUtils {
    // Chain ID of the spoke chain
    uint256 constant SPOKE_CHAIN_ID = 10; // Optimism chain ID

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get addresses specific to the current network
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL1Address(chainId, "cctpTokenMessenger");

        // Get OP_STACK addresses - these would typically be loaded from a central constants file
        address l1CrossDomainMessenger;
        address l1StandardBridge;

        // Set OP Stack addresses based on chainId and spoke chainId
        if (chainId == MAINNET && SPOKE_CHAIN_ID == OPTIMISM) {
            l1CrossDomainMessenger = 0x25ace71c97B33Cc4729CF772ae268934F7ab5fA1;
            l1StandardBridge = 0x99C9fc46f92E8a1c0deC1b1747d010903E884bE1;
        } else if (chainId == SEPOLIA && SPOKE_CHAIN_ID == OPTIMISM_SEPOLIA) {
            l1CrossDomainMessenger = 0x58Cc85b8D04EA49cC6DBd3CbFFd00B4B8D6cb3ef;
            l1StandardBridge = 0xFBb0621E0B23b5478B630BD55a5f21f67730B0F1;
        } else {
            revert("Unsupported chain combination");
        }

        console.log("Deploying Optimism Adapter on hub chain %s for spoke chain %s", chainId, SPOKE_CHAIN_ID);
        console.log("Deployer: %s", deployer);
        console.log("WETH: %s", weth);
        console.log("L1CrossDomainMessenger: %s", l1CrossDomainMessenger);
        console.log("L1StandardBridge: %s", l1StandardBridge);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Optimism_Adapter
        Optimism_Adapter adapter = new Optimism_Adapter(
            WETH9Interface(weth),
            l1CrossDomainMessenger,
            IL1StandardBridge(l1StandardBridge),
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Optimism_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();

        // Note: The verification would be handled by the foundry --verify flag during deployment
    }
}
