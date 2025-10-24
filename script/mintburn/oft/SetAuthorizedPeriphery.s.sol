// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";

import { DstOFTHandler } from "../../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";
import { Constants } from "../../utils/Constants.sol";

// Example runs:
// forge script script/mintburn/oft/SetAuthorizedPeriphery.s.sol:SetAuthorizedPeriphery \
//   --sig "run(uint256)" 10 \
//   --rpc-url hyperevm --broadcast -vvvv
// forge script script/mintburn/oft/SetAuthorizedPeriphery.s.sol:SetAuthorizedPeriphery \
//   --sig "run(string,uint256)" ./script/mintburn/oft/deployments.toml 10 \
//   --rpc-url hyperevm --broadcast -vvvv
contract SetAuthorizedPeriphery is Script, Config {
    using AddressToBytes32 for address;

    string internal constant DEFAULT_CONFIG_PATH = "./script/mintburn/oft/deployments.toml";

    function run() external {
        revert("Missing args. Use run(uint256) or run(string,uint256)");
    }

    function run(uint256 srcChainId) external {
        _run(DEFAULT_CONFIG_PATH, srcChainId);
    }

    function run(string memory configPath, uint256 srcChainId) external {
        _run(bytes(configPath).length == 0 ? DEFAULT_CONFIG_PATH : configPath, srcChainId);
    }

    function _run(string memory configPath, uint256 srcChainId) internal {
        // Load config and enable write-back
        _loadConfig(configPath, true);

        // Resolve deployer
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        // Read required params from TOML for specified chains
        address dstHandlerAddress = config.get("dst_handler").toAddress();
        address srcPeriphery = config.get(srcChainId, "src_periphery").toAddress();

        require(dstHandlerAddress != address(0), "dst_handler not set");
        require(srcPeriphery != address(0), "src_periphery not set");
        require(srcChainId != 0, "src_chain_id not set");

        // Compute src EID using local chain constants
        Constants constantsReader = new Constants();
        uint32 srcEid = uint32(constantsReader.getOftEid(srcChainId));

        console.log("Setting authorized periphery...");
        console.log("Dst chain:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Dst handler:", dstHandlerAddress);
        console.log("Src chain id:", srcChainId);
        console.log("Src EID:", uint256(srcEid));
        console.log("Src periphery:", srcPeriphery);

        DstOFTHandler dstHandler = DstOFTHandler(payable(dstHandlerAddress));

        vm.startBroadcast(deployerPrivateKey);
        dstHandler.setAuthorizedPeriphery(srcEid, srcPeriphery.toBytes32());
        vm.stopBroadcast();

        // Persist back to TOML under a namespaced key for traceability (dst chain section)
        string memory eidKey = string.concat("authorized_periphery_", vm.toString(uint256(srcEid)));
        config.set(eidKey, srcPeriphery);
        config.set("last_authorized_src_eid", uint256(srcEid));
        config.set("last_authorized_updated_at", block.timestamp);

        console.log("Authorized periphery saved to TOML with key:", eidKey);
    }
}
