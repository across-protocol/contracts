// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { DstHandlerConfigLib } from "./DstHandlerConfigLib.s.sol";

/*
forge script script/mintburn/oft/UpdateAuthorizedPeripheries.s.sol:UpdateAuthorizedPeripheries \
  --sig "run(string)" usdt0 \
  --rpc-url hyperevm --broadcast -vvvv
 */
contract UpdateAuthorizedPeripheries is Script, DstHandlerConfigLib {
    function run() external pure {
        revert("Missing args. Use run(string tokenKey)");
    }

    function run(string memory tokenKey) external {
        require(bytes(tokenKey).length != 0, "args");
        _run(tokenKey);
    }

    function _run(string memory tokenKey) internal {
        _loadTokenConfig(tokenKey);

        // Resolve deployer
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address dstHandlerAddress = config.get("dst_handler").toAddress();
        require(dstHandlerAddress != address(0), "dst_handler not set");

        console.log("Updating authorized peripheries on DstOFTHandler...");
        console.log("Dst chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Dst handler:", dstHandlerAddress);

        _configureAuthorizedPeripheries(dstHandlerAddress, deployerPrivateKey);
    }
}
