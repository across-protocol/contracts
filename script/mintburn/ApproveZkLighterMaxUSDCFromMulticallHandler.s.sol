// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PermissionedMulticallHandler } from "../../contracts/handlers/PermissionedMulticallHandler.sol";
import { MulticallHandler } from "../../contracts/handlers/MulticallHandler.sol";

/**
Approves zkLighter to spend USDC from the deployed PermissionedMulticallHandler by having the handler call USDC.approve().
Requires msg.sender (broadcast signer) to be whitelisted on PermissionedMulticallHandler.

@notice This script makes sense only with PermissionedMulticallHandler, with the API controlling what functions can be called
as a part of custom EVM execution. Otherwise, anyone can rescind the approval

Run:
forge script script/mintburn/ApproveZkLighterMaxUSDCFromMulticallHandler.s.sol:ApproveZkLighterMaxUSDCFromMulticallHandler \
  --rpc-url <network> -vvvv --broadcast
 */
contract ApproveZkLighterMaxUSDCFromMulticallHandler is Script, Config {
    function run() external {
        console.log("Approving zkLighter for max USDC from MulticallHandler...");
        console.log("Chain ID:", block.chainid);

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", false);

        address usdc = config.get("usdc").toAddress();
        address zkLighter = config.get("zkLighter").toAddress();
        address multicallHandlerAddr = config.get("multicallHandler").toAddress();

        require(usdc != address(0), "missing usdc in config");
        require(zkLighter != address(0), "missing zkLighter in config");
        require(multicallHandlerAddr != address(0), "missing multicallHandler in config");

        // Have the multicall handler itself execute: USDC.approve(zkLighter, type(uint256).max)
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](1);
        calls[0] = MulticallHandler.Call({
            target: usdc,
            callData: abi.encodeCall(IERC20.approve, (zkLighter, type(uint256).max)),
            value: 0
        });

        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            // fallbackRecipient == address(0) => revert if the approve fails, and no draining behavior.
            fallbackRecipient: address(0)
        });

        bytes memory message = abi.encode(instructions);

        vm.startBroadcast(pk);
        PermissionedMulticallHandler(payable(multicallHandlerAddr)).handleV3AcrossMessage(usdc, 0, address(0), message);
        vm.stopBroadcast();

        console.log("Done.");
        console.log("USDC:", usdc);
        console.log("zkLighter:", zkLighter);
        console.log("multicallHandler:", multicallHandlerAddr);
    }
}
