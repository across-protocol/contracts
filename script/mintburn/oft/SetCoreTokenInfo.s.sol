// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { ReadHCoreTokenInfoUtil } from "../ReadHCoreTokenInfoUtil.s.sol";
import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { HyperCoreFlowExecutor } from "../../../contracts/periphery/mintburn/HyperCoreFlowExecutor.sol";

// Example:
// forge script script/mintburn/oft/SetCoreTokenInfo.s.sol:SetCoreTokenInfo \
//   --sig "run(string,string)" usdt0 USDT0 \
//   --rpc-url hyperevm --broadcast -vvvv
contract SetCoreTokenInfo is Script, Config {
    function run() external pure {
        revert("Missing args. Use run(string tokenKey, string tokenName)");
    }

    function run(string memory tokenKey, string memory tokenName) external {
        require(bytes(tokenKey).length != 0 && bytes(tokenName).length != 0, "args");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenKey, ".toml"));
        _run(configPath, tokenName);
    }

    function _run(string memory configPath, string memory tokenName) internal {
        _loadConfig(configPath, true);

        // Resolve deployer
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address dstHandlerAddress = config.get("dst_handler").toAddress();
        require(dstHandlerAddress != address(0), "dst_handler not set");

        // Read token info from JSON
        ReadHCoreTokenInfoUtil.TokenJson memory tinfo = ReadHCoreTokenInfoUtil(address(new ReadHCoreTokenInfoUtil()))
            .readToken(tokenName);

        address tokenAddr = ReadHCoreTokenInfoUtil(address(new ReadHCoreTokenInfoUtil())).resolveEvmAddress(
            tinfo,
            block.chainid
        );

        require(tokenAddr != address(0), "token addr");

        console.log("Setting CoreTokenInfo on DstOFTHandler...");
        console.log("Dst chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Dst handler:", dstHandlerAddress);
        console.log("Token:", tokenAddr);

        vm.startBroadcast(deployerPrivateKey);
        HyperCoreFlowExecutor(dstHandlerAddress).setCoreTokenInfo(
            tokenAddr,
            uint32(tinfo.index),
            tinfo.canBeUsedForAccountActivation,
            uint64(tinfo.accountActivationFeeCore),
            uint64(tinfo.bridgeSafetyBufferCore)
        );
        vm.stopBroadcast();

        // Persist to TOML
        string memory key = string(abi.encodePacked("core_token_info_", tokenName));
        config.set(key, tokenAddr);
        config.set(string(abi.encodePacked(key, "_index")), uint256(tinfo.index));
        config.set(string(abi.encodePacked(key, "_canActivate")), tinfo.canBeUsedForAccountActivation);
        config.set(string(abi.encodePacked(key, "_activationFeeCore")), uint256(tinfo.accountActivationFeeCore));
        config.set(string(abi.encodePacked(key, "_bridgeSafetyBufferCore")), uint256(tinfo.bridgeSafetyBufferCore));
        config.set(string(abi.encodePacked(key, "_updated_at")), block.timestamp);
    }
}
