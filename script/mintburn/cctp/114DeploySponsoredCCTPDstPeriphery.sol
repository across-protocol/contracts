// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { SponsoredCCTPDstPeriphery } from "../../../contracts/periphery/mintburn/sponsored-cctp/SponsoredCCTPDstPeriphery.sol";

// Deploy: forge script script/mintburn/cctp/114DeploySponsoredCCTPDstPeriphery.sol:DeploySponsoredCCTPDstPeriphery --rpc-url <network> -vvvv
contract DeploySponsoredCCTPDstPeriphery is DeploymentUtils {
    function run() external {
        console.log("Deploying SponsoredCCTPDstPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadConfig("./script/mintburn/cctp/config.toml", true);

        address cctpMessageTransmitter = config.get("cctpTokenMessenger").toAddress();
        uint32 sourceDomain = config.get("cctpDomainId").toUint32();

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();
        console.log("DonationBox deployed to:", address(donationBox));

        // USDC on HyperEVM Testnet
        // address baseToken = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
        // USDC on HyperEVM Mainnet
        address baseToken = config.get("baseToken").toAddress();
        uint32 coreIndex = config.get("coreIndex").toUint32();
        bool canBeUsedForAccountActivation = config.get("canBeUsedForAccountActivation").toBool();
        uint64 accountActivationFeeCore = config.get("accountActivationFeeCore").toUint64();
        uint64 bridgeSafetyBufferCore = config.get("bridgeSafetyBufferCore").toUint64();

        SponsoredCCTPDstPeriphery sponsoredCCTPDstPeriphery = new SponsoredCCTPDstPeriphery(
            cctpMessageTransmitter,
            deployer,
            address(donationBox),
            baseToken,
            address(0)
        );

        console.log("SponsoredCCTPDstPeriphery deployed to:", address(sponsoredCCTPDstPeriphery));

        donationBox.transferOwnership(address(sponsoredCCTPDstPeriphery));

        console.log("DonationBox ownership transferred to:", address(sponsoredCCTPDstPeriphery));

        vm.stopBroadcast();
    }
}
