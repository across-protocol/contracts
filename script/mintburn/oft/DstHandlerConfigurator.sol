// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Config } from "forge-std/Config.sol";
import { console } from "forge-std/console.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";

import { ReadHCoreTokenInfoUtil } from "../../mintburn/ReadHCoreTokenInfoUtil.s.sol";
import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { HyperCoreFlowExecutor } from "../../../contracts/periphery/mintburn/HyperCoreFlowExecutor.sol";
import { IOAppCore, IEndpoint } from "../../../contracts/interfaces/IOFT.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";

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
    }

    function _configureAuthorizedPeripheries(address dstHandlerAddress) internal {
        require(dstHandlerAddress != address(0), "dst handler not set");

        DstOFTHandler handler = DstOFTHandler(payable(dstHandlerAddress));
        uint256[] memory chainIdList = config.getChainIds();

        uint256 dstForkId = forkOf[block.chainid];
        require(dstForkId != 0, "dst chain not in config");

        for (uint256 i = 0; i < chainIdList.length; i++) {
            uint256 srcChainId = chainIdList[i];
            address srcPeriphery = config.get(srcChainId, "src_periphery").toAddress();
            address oftMessenger = config.get(srcChainId, "oft_messenger").toAddress();
            if (srcPeriphery == address(0) || oftMessenger == address(0)) {
                console.log(
                    "Skipping authorizing periphery for chain",
                    srcChainId,
                    "srcPeriphery or oftMessenger not set"
                );
                continue;
            }

            uint256 srcForkId = forkOf[block.chainid];
            require(srcForkId != 0, "dst chain not in config");

            // Switch to calling src chain contracts to get srcEid
            vm.selectFork(srcForkId);

            uint32 srcEid;
            try IOAppCore(oftMessenger).endpoint() returns (IEndpoint ep) {
                srcEid = ep.eid();
            } catch {
                continue;
            }

            // Switch to calling src chain contracts to read dst chain state + update periphery if needed
            vm.selectFork(dstForkId);

            bytes32 expected = srcPeriphery.toBytes32();
            if (handler.authorizedSrcPeripheryContracts(uint64(srcEid)) != expected) {
                console.log("Authorizing periphery", srcPeriphery, "for srcEid", uint256(srcEid));
                handler.setAuthorizedPeriphery(srcEid, expected);
            }
        }
    }
}
