// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";

// How to run:
// 1. source .env (needs MNEMONIC and the relevant NODE_URL_*)
// 2. forge script script/mintburn/cctp/SetUpTokens.s.sol:SetUpTokens --rpc-url <chain> --sig "run(string)" <chain> -vvvv
contract SetUpTokens is DeploymentUtils {
    function run(string calldata chain) external {
        console.log("Setting up core token info...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);

        _loadConfig("./script/mintburn/cctp/config.toml", false);

        address dstPeriphery = config.get("sponsoredCCTPDstPeriphery").toAddress();
        address baseToken = config.get("baseToken").toAddress();
        uint256 coreIndex = config.get("coreIndex").toUint256();
        uint256 accountActivationFeeCore = config.get("accountActivationFeeCore").toUint256();
        uint256 bridgeSafetyBufferCore = config.get("bridgeSafetyBufferCore").toUint256();
        bool canBeUsedForAccountActivation = config.get("canBeUsedForAccountActivation").toBool();

        string memory chain = chain;
        string memory dstPeripheryStr = vm.toString(dstPeriphery);
        string memory baseTokenStr = vm.toString(baseToken);
        string memory coreIndexStr = vm.toString(coreIndex);
        string memory accountActivationFeeCoreStr = vm.toString(accountActivationFeeCore);
        string memory bridgeSafetyBufferCoreStr = vm.toString(bridgeSafetyBufferCore);
        string memory canBeUsedForAccountActivationStr = canBeUsedForAccountActivation ? "true" : "false";

        // Set core token info
        console.log("# Setting core token info...");
        string[] memory sendCmd = new string[](13);
        sendCmd[0] = "cast";
        sendCmd[1] = "send";
        sendCmd[2] = dstPeripheryStr;
        sendCmd[3] = "setCoreTokenInfo(address,uint32,bool,uint64,uint64)";
        sendCmd[4] = baseTokenStr;
        sendCmd[5] = coreIndexStr;
        sendCmd[6] = canBeUsedForAccountActivationStr;
        sendCmd[7] = accountActivationFeeCoreStr;
        sendCmd[8] = bridgeSafetyBufferCoreStr;
        sendCmd[9] = "--account";
        sendCmd[10] = "dev";
        sendCmd[11] = "--rpc-url";
        sendCmd[12] = chain;

        bytes memory sendResult = vm.ffi(sendCmd);
        console.log("setCoreTokenInfo result:", string(sendResult));
    }
}
