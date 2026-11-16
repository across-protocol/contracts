// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DonationBox } from "../../contracts/chain-adapters/DonationBox.sol";
import { PermissionedMulticallHandler } from "../../contracts/handlers/PermissionedMulticallHandler.sol";
import { MulticallHandler } from "../../contracts/handlers/MulticallHandler.sol";

/**
 * Migrates a token balance from one DonationBox to another by having the deployed PermissionedMulticallHandler:
 *   1. Call `DonationBox.withdraw(token, amount)` on the old DonationBox (the handler must hold WITHDRAWER_ROLE),
 *      which sends the tokens to the handler itself.
 *   2. Call `IERC20.transfer(newDonationBox, amount)` to forward those tokens to the new DonationBox.
 *
 * Requires msg.sender (broadcast signer) to be whitelisted on PermissionedMulticallHandler.
 *
 * @notice This script makes sense only with PermissionedMulticallHandler, with the API controlling what functions can be called
 * as a part of custom EVM execution. Otherwise, anyone could redirect the funds.
 *
 * Run:
 * forge script script/mintburn/MigrateDonationBoxFundsFromMulticallHandler.s.sol:MigrateDonationBoxFundsFromMulticallHandler \
 *   --rpc-url <network> -vvvv --broadcast
 */
contract MigrateDonationBoxFundsFromMulticallHandler is Script, Config {
    function run() external {
        console.log("Migrating DonationBox funds via MulticallHandler...");
        console.log("Chain ID:", block.chainid);

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);
        console.log("Deployer:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", false);

        address token = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address oldDonationBox = 0x1648fC159a5c13c060EFdF44f3CEE9bD184fa168;
        address newDonationBox = 0x109Db572e719Fa363dC53Fbaf3617422159060c9;
        address multicallHandlerAddr = 0x64a43393866DBA0044879979fAa7AD3d000622e9;

        require(token != address(0), "missing token in config");
        require(oldDonationBox != address(0), "missing oldDonationBox in config");
        require(newDonationBox != address(0), "missing newDonationBox in config");
        require(multicallHandlerAddr != address(0), "missing multicallHandler in config");
        require(oldDonationBox != newDonationBox, "old and new DonationBox must differ");

        uint256 amount = 5_508_438_284;
        require(amount > 0, "old DonationBox has zero token balance");

        // 1) Old DonationBox sends `amount` of `token` to the MulticallHandler (msg.sender of withdraw).
        // 2) MulticallHandler transfers `amount` of `token` to the new DonationBox.
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](2);
        calls[0] = MulticallHandler.Call({
            target: oldDonationBox,
            callData: abi.encodeCall(DonationBox.withdraw, (IERC20(token), amount)),
            value: 0
        });
        calls[1] = MulticallHandler.Call({
            target: token,
            callData: abi.encodeCall(IERC20.transfer, (newDonationBox, amount)),
            value: 0
        });

        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            // fallbackRecipient == address(0) => revert if any call fails, and no draining behavior.
            fallbackRecipient: address(0)
        });

        bytes memory message = abi.encode(instructions);

        // vm.startBroadcast(pk);
        // PermissionedMulticallHandler(payable(multicallHandlerAddr)).handleV3AcrossMessage(token, 0, address(0), message);
        // vm.stopBroadcast();

        console.log("Done.");
        console.log("token:", token);
        console.logBytes(message);
        console.log("amount:", amount);
        console.log("oldDonationBox:", oldDonationBox);
        console.log("newDonationBox:", newDonationBox);
        console.log("multicallHandler:", multicallHandlerAddr);
    }
}
