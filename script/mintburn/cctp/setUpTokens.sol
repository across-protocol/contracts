// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";

import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";
import { HyperCoreFlowExecutor } from "../../../contracts/periphery/mintburn/HyperCoreFlowExecutor.sol";

contract setUpTokens is Script, Config {
    function run() external {
        console.log("Setting up tokens...");

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address baseToken = config.get("baseToken").toAddress();
        uint32 coreIndex = config.get("coreIndex").toUint32();
        bool canBeUsedForAccountActivation = config.get("canBeUsedForAccountActivation").toBool();
        uint64 accountActivationFeeCore = config.get("accountActivationFeeCore").toUint64();
        uint64 bridgeSafetyBufferCore = config.get("bridgeSafetyBufferCore").toUint64();

        // DonationBox@0x6f1Cd5f317a7228269EaB2b496313862de712CCb
        // SponsoredCCTPDstPeriphery@0x06C61D54958a0772Ee8aF41789466d39FfeaeB13
        // HyperCoreFlowExecutor@0x82C8aB69e358F354eCb7Ff35239Cd326DeFf2072
        HyperCoreFlowExecutor dstPeriphery = HyperCoreFlowExecutor(payable(0xF962E0e485A5B9f8aDa9a438cEecc35c0020B6e7));

        vm.startBroadcast(deployerPrivateKey);
        console.log(
            "Checking if sender has DEFAULT_ADMIN_ROLE:",
            dstPeriphery.hasRole(dstPeriphery.DEFAULT_ADMIN_ROLE(), deployer)
        );
        // dstPeriphery.setCoreTokenInfo(
        //     baseToken,
        //     coreIndex,
        //     canBeUsedForAccountActivation,
        //     accountActivationFeeCore,
        //     bridgeSafetyBufferCore
        // );

        console.log("Core token info set for:", baseToken);
        console.log("Core index:", coreIndex);
        console.log("Can be used for account activation:", canBeUsedForAccountActivation);
        console.log("Account activation fee core:", accountActivationFeeCore);
        console.log("Bridge safety buffer core:", bridgeSafetyBufferCore);

        vm.stopBroadcast();
    }
}
