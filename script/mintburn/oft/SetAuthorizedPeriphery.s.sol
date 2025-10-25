// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { IOAppCore, IEndpoint } from "../../../contracts/interfaces/IOFT.sol";

/*
Example usage:

# Update authorized peripheries on current destination chain using token config
forge script script/mintburn/oft/SetAuthorizedPeriphery.s.sol:UpdateAuthorizedPeripheries \
  --sig "run(string)" usdt0 \
  --rpc-url hyperevm -vvvv --broadcast
*/

contract UpdateAuthorizedPeripheries is Script, Config {
    using AddressToBytes32 for address;

    function run() external pure {
        revert("Missing args. Use run(string tokenName)");
    }

    function run(string memory tokenName) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _run(configPath);
    }

    function _run(string memory configPath) internal {
        _loadConfigAndForks(configPath, true);

        // Destination context
        uint256 dstChainId = block.chainid;
        uint256 dstForkId = forkOf[dstChainId];
        require(dstForkId != 0, "dst chain not in config");
        vm.selectFork(dstForkId);

        address dstHandlerAddress = config.get("dst_handler").toAddress();
        require(dstHandlerAddress != address(0), "dst_handler not set");

        // Resolve deployer once
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Updating authorized peripheries on dst chain:", dstChainId);
        console.log("Dst handler:", dstHandlerAddress);
        console.log("Deployer:", deployer);

        DstOFTHandler dstHandler = DstOFTHandler(payable(dstHandlerAddress));

        bool performedUpdates = false;
        vm.startBroadcast(deployerPrivateKey);

        // Iterate over all chains configured in the TOML
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 srcChainId = chainIds[i];

            // Switch to source chain fork to read its messenger + endpoint EID
            uint256 srcForkId = forkOf[srcChainId];
            if (srcForkId == 0) continue;
            vm.selectFork(srcForkId);

            address srcPeriphery = config.get("src_periphery").toAddress();
            address oftMessenger = config.get("oft_messenger").toAddress();
            if (srcPeriphery == address(0) || oftMessenger == address(0)) {
                // Nothing to do for this chain
                continue;
            }

            uint32 srcEid;
            try IOAppCore(oftMessenger).endpoint() returns (IEndpoint ep) {
                srcEid = ep.eid();
            } catch {
                continue;
            }

            // Switch back to destination chain to compare/update
            vm.selectFork(dstForkId);

            bytes32 current = dstHandler.authorizedSrcPeripheryContracts(uint64(srcEid));
            bytes32 expected = srcPeriphery.toBytes32();

            if (current != expected) {
                console.log("Updating srcEid:", uint256(srcEid), "to", srcPeriphery);
                dstHandler.setAuthorizedPeriphery(srcEid, expected);
                performedUpdates = true;

                // Persist back to TOML under a namespaced key for traceability (dst chain section)
                string memory eidKey = string.concat("authorized_periphery_", vm.toString(uint256(srcEid)));
                config.set(eidKey, srcPeriphery);
            }
        }

        vm.stopBroadcast();

        // Additional trace metadata
        if (performedUpdates) {
            config.set("last_authorized_updated_at", block.timestamp);
        }

        console.log(performedUpdates ? "Updates complete" : "No updates required");
    }
}
