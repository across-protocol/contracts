// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { ReadHCoreTokenInfoUtil } from "../mintburn/ReadHCoreTokenInfoUtil.s.sol";
import { DstOFTHandler } from "../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { HyperCoreFlowExecutor } from "../../contracts/periphery/mintburn/HyperCoreFlowExecutor.sol";
import { IOAppCore, IEndpoint } from "../../contracts/interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../contracts/libraries/AddressConverters.sol";

/// @notice Shared helper for configuring `DstOFTHandler` instances using TOML and JSON metadata.
abstract contract DstHandlerConfigurator is Config {
    using AddressToBytes32 for address;

    function _loadTokenConfig(string memory tokenKey) internal {
        require(bytes(tokenKey).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenKey, ".toml"));
        _loadConfig(configPath, true);
    }

    function _configureCoreTokenInfo(string memory tokenName, address dstHandlerAddress) internal {
        require(dstHandlerAddress != address(0), "dst handler not set");

        ReadHCoreTokenInfoUtil reader = new ReadHCoreTokenInfoUtil();
        ReadHCoreTokenInfoUtil.TokenJson memory info = reader.readToken(tokenName);
        address tokenAddr = reader.resolveEvmAddress(info, block.chainid);
        require(tokenAddr != address(0), "token addr missing");

        console.log("Configuring CoreTokenInfo for", tokenName);
        console.log("Dst handler:", dstHandlerAddress);
        console.log("Token:", tokenAddr);

        HyperCoreFlowExecutor(dstHandlerAddress).setCoreTokenInfo(
            tokenAddr,
            uint32(info.index),
            info.canBeUsedForAccountActivation,
            uint64(info.accountActivationFeeCore),
            uint64(info.bridgeSafetyBufferCore)
        );

        string memory key = string(abi.encodePacked("core_token_info_", tokenName));
        config.set(key, tokenAddr);
        config.set(string(abi.encodePacked(key, "_index")), uint256(info.index));
        config.set(string(abi.encodePacked(key, "_canActivate")), info.canBeUsedForAccountActivation);
        config.set(string(abi.encodePacked(key, "_activationFeeCore")), uint256(info.accountActivationFeeCore));
        config.set(string(abi.encodePacked(key, "_bridgeSafetyBufferCore")), uint256(info.bridgeSafetyBufferCore));
        config.set(string(abi.encodePacked(key, "_updated_at")), block.timestamp);
    }

    function _configureAuthorizedPeripheries(address dstHandlerAddress) internal {
        require(dstHandlerAddress != address(0), "dst handler not set");

        DstOFTHandler handler = DstOFTHandler(payable(dstHandlerAddress));
        uint256[] memory chainIdList = config.getChainIds();
        bool updated;

        for (uint256 i = 0; i < chainIdList.length; i++) {
            uint256 srcChainId = chainIdList[i];
            address srcPeriphery = config.get(srcChainId, "src_periphery").toAddress();
            address oftMessenger = config.get(srcChainId, "oft_messenger").toAddress();
            if (srcPeriphery == address(0) || oftMessenger == address(0)) {
                continue;
            }

            uint32 srcEid;
            try IOAppCore(oftMessenger).endpoint() returns (IEndpoint ep) {
                srcEid = ep.eid();
            } catch {
                continue;
            }

            bytes32 expected = srcPeriphery.toBytes32();
            if (handler.authorizedSrcPeripheryContracts(uint64(srcEid)) != expected) {
                console.log("Authorizing periphery", srcPeriphery, "for srcEid", uint256(srcEid));
                handler.setAuthorizedPeriphery(srcEid, expected);
                updated = true;

                string memory eidKey = string.concat("authorized_periphery_", Strings.toString(uint256(srcEid)));
                config.set(srcChainId, eidKey, srcPeriphery);
            }
        }

        if (updated) {
            config.set("last_authorized_updated_at", block.timestamp);
        }
    }
}
