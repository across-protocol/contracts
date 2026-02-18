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

        // 1. Check DEFAULT_ADMIN_ROLE
        console.log("# Checking DEFAULT_ADMIN_ROLE...");
        string[] memory callCmd = new string[](6);
        callCmd[0] = "cast";
        callCmd[1] = "call";
        callCmd[2] = dstPeripheryStr;
        callCmd[3] = "DEFAULT_ADMIN_ROLE()(bytes32)";
        callCmd[4] = "--rpc-url";
        callCmd[5] = chain;
        bytes memory roleResult = vm.ffi(callCmd);
        // vm.ffi hex-decodes output starting with 0x, so convert raw bytes back to a hex string.
        string memory role = vm.toString(bytes32(roleResult));
        console.log("DEFAULT_ADMIN_ROLE:", role);

        // 2. Check if deployer has DEFAULT_ADMIN_ROLE
        console.log("# Checking if deployer has DEFAULT_ADMIN_ROLE...");
        string[] memory hasRoleCmd = new string[](8);
        hasRoleCmd[0] = "cast";
        hasRoleCmd[1] = "call";
        hasRoleCmd[2] = dstPeripheryStr;
        hasRoleCmd[3] = "hasRole(bytes32,address)(bool)";
        hasRoleCmd[4] = role;
        hasRoleCmd[5] = vm.toString(deployer);
        hasRoleCmd[6] = "--rpc-url";
        hasRoleCmd[7] = chain;
        bytes memory hasRoleResult = vm.ffi(hasRoleCmd);
        console.log("Deployer has admin role:", string(hasRoleResult));

        // 3. Set core token info
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
