// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { Constants } from "../../utils/Constants.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../../../contracts/periphery/mintburn/sponsored-oft/Structs.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { ComposeMsgCodec } from "../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";
import { MinimalLZOptions } from "../../../contracts/external/libraries/MinimalLZOptions.sol";
import { IOFT, IOAppCore, SendParam, MessagingFee } from "../../../contracts/interfaces/IOFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Used in place of // import { QuoteSignLib } from "../contracts/periphery/mintburn/sponsored-oft/QuoteSignLib.sol";
/// just for the hashing function that works with a memory funciton argument
library DebugQuoteSignLib {
    /// @notice Compute the keccak of all `SignedQuoteParams` fields. Accept memory arg
    function hashMemory(SignedQuoteParams memory p) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    p.srcEid,
                    p.dstEid,
                    p.destinationHandler,
                    p.amountLD,
                    p.nonce,
                    p.deadline,
                    p.maxBpsToSponsor,
                    p.finalRecipient,
                    p.finalToken,
                    p.lzReceiveGasLimit,
                    p.lzComposeGasLimit,
                    p.executionMode,
                    keccak256(p.actionData) // Hash the actionData to keep signature size reasonable
                )
            );
    }
}
/*
forge script script/mintburn/oft/CreateSponsoredDeposit.sol:CreateSponsoredDeposit \
  --sig "run(string,uint256,uint256)" usdt0 999 1234569 \
  --rpc-url arbitrum -vvvv --broadcast

Run script with:

forge script script/mintburn/oft/CreateSponsoredDeposit.sol:CreateSponsoredDeposit \
  --sig "run(string,uint256,uint256)" usdt0 <DST_CHAIN_ID> <AMOUNT_LD> \
  --rpc-url <SRC_RPC_ALIAS> -vvvv --broadcast

or, explicitly provide src chain id:

forge script script/mintburn/oft/CreateSponsoredDeposit.sol:CreateSponsoredDeposit \
  --sig "run(string,uint256,uint256,uint256)" usdt0 <SRC_CHAIN_ID> <DST_CHAIN_ID> <AMOUNT_LD> \
  --rpc-url <SRC_RPC_ALIAS> -vvvv --broadcast
*/
contract CreateSponsoredDeposit is Script, Config, Constants {
    using AddressToBytes32 for address;
    using SafeERC20 for IERC20;
    using MinimalLZOptions for bytes;

    struct ChainConfig {
        address srcPeriphery;
        address token;
        address dstHandler;
        address finalToken;
        uint32 srcEid;
        uint32 dstEid;
        uint256 srcForkId;
    }

    struct FlowParams {
        uint256 amountLD;
        uint256 deadline;
        uint256 maxBpsToSponsor;
        uint256 maxUserSlippageBps;
        uint256 lzReceiveGasLimit;
        uint256 lzComposeGasLimit;
        address refundRecipient;
        address finalRecipient;
        bytes32 nonce;
    }

    function run(string memory tokenKey, uint256 dstChainId, uint256 amountLD) external {
        // Derive srcChainId from the current RPC
        _run(tokenKey, block.chainid, dstChainId, amountLD);
    }

    function run(string memory tokenKey, uint256 srcChainId, uint256 dstChainId, uint256 amountLD) external {
        _run(tokenKey, srcChainId, dstChainId, amountLD);
    }

    function _run(string memory tokenKey, uint256 srcChainId, uint256 dstChainId, uint256 amountLD) internal {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);

        _loadTokenConfig(tokenKey);

        ChainConfig memory cfg = _resolveChainConfig(srcChainId, dstChainId);
        FlowParams memory fp = _buildDefaultFlowParams(amountLD, deployer);

        SponsoredOFTSrcPeriphery periphery = SponsoredOFTSrcPeriphery(cfg.srcPeriphery);
        require(periphery.signer() == deployer, "quote signer mismatch");

        (Quote memory quote, bytes32 digest) = _buildQuote(cfg, fp);
        bytes memory sig = _signQuote(digest, deployerPrivateKey);

        _broadcastFlow(periphery, cfg, fp, quote, sig, deployerPrivateKey);
    }

    function _quoteMessagingFee(
        SponsoredOFTSrcPeriphery srcPeripheryContract,
        Quote memory quote
    ) internal view returns (MessagingFee memory) {
        bytes memory composeMsg = _encodeComposeMsg(quote);
        bytes memory extraOptions = _buildLZOptions(
            quote.signedParams.lzReceiveGasLimit,
            quote.signedParams.lzComposeGasLimit
        );
        SendParam memory sendParam = _buildSendParam(
            quote,
            composeMsg,
            extraOptions,
            srcPeripheryContract.EMPTY_OFT_COMMAND()
        );
        return IOFT(srcPeripheryContract.OFT_MESSENGER()).quoteSend(sendParam, false);
    }

    function _encodeComposeMsg(Quote memory quote) internal pure returns (bytes memory) {
        return
            ComposeMsgCodec._encode(
                quote.signedParams.nonce,
                quote.signedParams.deadline,
                quote.signedParams.maxBpsToSponsor,
                quote.unsignedParams.maxUserSlippageBps,
                quote.signedParams.finalRecipient,
                quote.signedParams.finalToken,
                quote.signedParams.executionMode,
                quote.signedParams.actionData
            );
    }

    function _buildLZOptions(uint256 receiveGas, uint256 composeGas) internal pure returns (bytes memory) {
        return
            MinimalLZOptions
                .newOptions()
                .addExecutorLzReceiveOption(uint128(receiveGas), uint128(0))
                .addExecutorLzComposeOption(uint16(0), uint128(composeGas), uint128(0));
    }

    function _buildSendParam(
        Quote memory quote,
        bytes memory composeMsg,
        bytes memory extraOptions,
        bytes memory oftCmd
    ) internal pure returns (SendParam memory) {
        return
            SendParam({
                dstEid: quote.signedParams.dstEid,
                to: quote.signedParams.destinationHandler,
                amountLD: quote.signedParams.amountLD,
                minAmountLD: quote.signedParams.amountLD,
                extraOptions: extraOptions,
                composeMsg: composeMsg,
                oftCmd: oftCmd
            });
    }

    function _resolveChainConfig(uint256 srcChainId, uint256 dstChainId) internal returns (ChainConfig memory cfg) {
        uint256 srcForkId = forkOf[srcChainId];
        if (srcForkId != 0) {
            vm.selectFork(srcForkId);
        } else {
            require(block.chainid == srcChainId, "select src RPC or add endpoint_url");
        }

        address srcPeriphery = config.get(srcChainId, "src_periphery").toAddress();
        address token = config.get(srcChainId, "token").toAddress();
        address dstHandler = config.get(dstChainId, "dst_handler").toAddress();
        address finalToken = config.get(dstChainId, "token").toAddress();
        require(srcPeriphery != address(0) && token != address(0), "src config missing");
        require(dstHandler != address(0) && finalToken != address(0), "dst config missing");

        uint32 srcEid = _resolveEid(srcChainId);
        uint32 dstEid = _resolveEid(dstChainId);

        if (srcForkId != 0) {
            vm.selectFork(srcForkId);
        } else {
            require(block.chainid == srcChainId, "not on src RPC after EID resolution");
        }

        cfg = ChainConfig({
            srcPeriphery: srcPeriphery,
            token: token,
            dstHandler: dstHandler,
            finalToken: finalToken,
            srcEid: srcEid,
            dstEid: dstEid,
            srcForkId: srcForkId
        });
    }

    function _buildDefaultFlowParams(uint256 amountLD, address deployer) internal view returns (FlowParams memory fp) {
        fp.amountLD = amountLD;
        fp.deadline = block.timestamp + 1 hours;
        fp.maxBpsToSponsor = 100;
        fp.maxUserSlippageBps = 50;
        fp.lzReceiveGasLimit = 200_000;
        fp.lzComposeGasLimit = 300_000;
        fp.refundRecipient = deployer;
        fp.finalRecipient = deployer;
        fp.nonce = bytes32(uint256(block.timestamp));
    }

    function _buildQuote(
        ChainConfig memory cfg,
        FlowParams memory fp
    ) internal pure returns (Quote memory quote, bytes32 digest) {
        SignedQuoteParams memory sp = SignedQuoteParams({
            srcEid: cfg.srcEid,
            dstEid: cfg.dstEid,
            destinationHandler: cfg.dstHandler.toBytes32(),
            amountLD: fp.amountLD,
            nonce: fp.nonce,
            deadline: fp.deadline,
            maxBpsToSponsor: fp.maxBpsToSponsor,
            finalRecipient: fp.finalRecipient.toBytes32(),
            finalToken: cfg.finalToken.toBytes32(),
            lzReceiveGasLimit: fp.lzReceiveGasLimit,
            lzComposeGasLimit: fp.lzComposeGasLimit,
            executionMode: 0,
            actionData: ""
        });

        UnsignedQuoteParams memory usp = UnsignedQuoteParams({
            refundRecipient: fp.refundRecipient,
            maxUserSlippageBps: fp.maxUserSlippageBps
        });

        quote = Quote({ signedParams: sp, unsignedParams: usp });
        digest = DebugQuoteSignLib.hashMemory(sp);
    }

    function _signQuote(bytes32 digest, uint256 deployerPrivateKey) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _broadcastFlow(
        SponsoredOFTSrcPeriphery periphery,
        ChainConfig memory cfg,
        FlowParams memory fp,
        Quote memory quote,
        bytes memory sig,
        uint256 deployerPrivateKey
    ) internal {
        MessagingFee memory fee = _quoteMessagingFee(periphery, quote);

        vm.startBroadcast(deployerPrivateKey);
        IERC20(cfg.token).forceApprove(cfg.srcPeriphery, fp.amountLD);
        periphery.deposit{ value: fee.nativeFee }(quote, sig);
        vm.stopBroadcast();
    }

    function _resolveEid(uint256 chainId) internal returns (uint32) {
        // If we're already on this chain, read directly
        if (block.chainid == chainId) {
            address ioftCurrent = config.get(chainId, "oft_messenger").toAddress();
            if (ioftCurrent != address(0)) {
                return IOAppCore(ioftCurrent).endpoint().eid();
            }
        }

        // If a fork exists, switch to it and read
        uint256 forkId = forkOf[chainId];
        if (forkId != 0) {
            vm.selectFork(forkId);
            address ioft = config.get(chainId, "oft_messenger").toAddress();
            require(ioft != address(0), "oft messenger missing");
            return IOAppCore(ioft).endpoint().eid();
        }

        // Fallback to constants if no fork; ensures robustness
        uint256 eid = getOftEid(chainId);
        require(eid != 0, "eid unavailable");
        return uint32(eid);
    }

    function _loadTokenConfig(string memory tokenKey) internal {
        require(bytes(tokenKey).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenKey, ".toml"));
        _loadConfigAndForks(configPath, true);
    }
}
