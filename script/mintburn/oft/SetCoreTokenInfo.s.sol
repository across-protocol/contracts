// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { DstHandlerConfigurator } from "./DstHandlerConfigurator.sol";

// Example:
// forge script script/mintburn/oft/SetCoreTokenInfo.s.sol:SetCoreTokenInfo \
//   --sig "run(string,string)" usdt0 USDT0 \
//   --rpc-url hyperevm --broadcast -vvvv
contract SetCoreTokenInfo is Script, DstHandlerConfigurator {
    function run() external pure {
        revert("Missing args. Use run(string tokenKey, string tokenName)");
    }

    function run(string memory tokenKey, string memory tokenName) external {
        require(bytes(tokenKey).length != 0 && bytes(tokenName).length != 0, "args");
        _run(tokenKey, tokenName);
    }

    function _run(string memory tokenKey, string memory tokenName) internal {
        _loadTokenConfig(tokenKey);

        // Resolve deployer
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address dstHandlerAddress = config.get("dst_handler").toAddress();
        require(dstHandlerAddress != address(0), "dst_handler not set");

        console.log("Setting CoreTokenInfo on DstOFTHandler...");
        console.log("Dst chain:", block.chainid);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);
        _configureCoreTokenInfo(tokenName, dstHandlerAddress);
        vm.stopBroadcast();
    }
}
