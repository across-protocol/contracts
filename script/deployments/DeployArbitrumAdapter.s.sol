// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Arbitrum_Adapter } from "../../contracts/chain-adapters/Arbitrum_Adapter.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { ArbitrumInboxLike as ArbitrumL1InboxLike, ArbitrumL1ERC20GatewayLike } from "../../contracts/interfaces/ArbitrumBridge.sol";

/**
 * @title DeployArbitrumAdapter
 * @notice Deploys the Arbitrum adapter contract.
 * @dev Migration of 004_deploy_arbitrum_adapter.ts script to Foundry.
 */
contract DeployArbitrumAdapter is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // This address receives gas refunds on the L2 after messages are relayed
        address l2RefundAddress = vm.envOr("L2_REFUND_ADDRESS", address(0x07aE8551Be970cB1cCa11Dd7a11F47Ae82e70E67));

        // Get addresses specific to the current network
        address l1ArbitrumInbox = getL1Address(chainId, "l1ArbitrumInbox");
        address l1ERC20GatewayRouter = getL1Address(chainId, "l1ERC20GatewayRouter");
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL1Address(chainId, "cctpTokenMessenger");

        console.log("Deploying Arbitrum Adapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("L1 Arbitrum Inbox: %s", l1ArbitrumInbox);
        console.log("L1 ERC20 Gateway Router: %s", l1ERC20GatewayRouter);
        console.log("L2 Refund Address: %s", l2RefundAddress);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Arbitrum_Adapter
        Arbitrum_Adapter adapter = new Arbitrum_Adapter(
            ArbitrumL1InboxLike(l1ArbitrumInbox),
            ArbitrumL1ERC20GatewayLike(l1ERC20GatewayRouter),
            l2RefundAddress,
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Arbitrum_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }
}
