// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { Vm } from "forge-std/Vm.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../../../contracts/periphery/mintburn/sponsored-oft/Structs.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { ComposeMsgCodec } from "../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";
import { MinimalLZOptions } from "../../../contracts/external/libraries/MinimalLZOptions.sol";
import { IOFT, SendParam, MessagingFee, IOAppCore } from "../../../contracts/interfaces/IOFT.sol";
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

    /// @notice Sign the quote using Foundry's Vm cheatcode and return concatenated bytes signature (r,s,v).
    function signMemory(Vm vm, uint256 pk, SignedQuoteParams memory p) internal pure returns (bytes memory) {
        bytes32 digest = hashMemory(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

/*
Examples:

- Simple transfer (no swap), sponsored (e.g. 1%):
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256)" usdt0 1000000 100 --rpc-url arbitrum -vvvv

- Simple transfer (no swap), non-sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256)" usdt0 1000000 0 --rpc-url arbitrum -vvvv

- Simple transfer (no swap) with explicit recipient, sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256)" usdt0 1000000 0xRecipient 100 --rpc-url arbitrum -vvvv

- Simple transfer (no swap) with explicit recipient, non-sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256)" usdt0 1000000 0xRecipient 0 --rpc-url arbitrum -vvvv

- Swap flow (finalToken specified), sponsored (e.g. 1%):
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,address)" usdt0 1000000 100 0xFinalToken --rpc-url arbitrum -vvvv

- Swap flow (finalToken specified), non-sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,address)" usdt0 1000000 0 0xFinalToken --rpc-url arbitrum -vvvv

- Swap flow with explicit recipient, sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256,address)" usdt0 1000000 0xRecipient 100 0xFinalToken --rpc-url arbitrum -vvvv
*/
contract CreateSponsoredDeposit is Script, Config {
    using AddressToBytes32 for address;
    using SafeERC20 for IERC20;
    using MinimalLZOptions for bytes;

    struct DepositEnv {
        address srcPeriphery;
        address token;
        address destinationHandler;
        address dstToken;
        uint32 srcEid;
        uint32 dstEid;
    }

    function run() external pure {
        revert("see header for supported run signatures");
    }

    function run(string memory) external pure {
        revert("see header for supported run signatures");
    }

    /// @notice Simple transfer entrypoint: finalToken defaults to the input token from config, recipient defaults to signer.
    function run(string memory tokenName, uint256 amountLD, uint256 maxBpsToSponsor) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);
        DepositEnv memory env = _resolveEnv();

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);

        address recipient = deployer;
        address finalToken = env.dstToken; // default to destination token: simple transfer
        _execute(env, pk, deployer, amountLD, recipient, maxBpsToSponsor, finalToken);
    }

    /// @notice Simple transfer entrypoint with explicit recipient (finalToken defaults to the input token).
    function run(string memory tokenName, uint256 amountLD, address finalRecipient, uint256 maxBpsToSponsor) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);
        DepositEnv memory env = _resolveEnv();

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        address finalToken = env.dstToken; // simple transfer uses destination token
        _execute(env, pk, deployer, amountLD, recipient, maxBpsToSponsor, finalToken);
    }

    /// @notice Run with default finalRecipient = signer, and custom sponsorship and finalToken (swap) configuration.
    function run(string memory tokenName, uint256 amountLD, uint256 maxBpsToSponsor, address finalToken) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);
        DepositEnv memory env = _resolveEnv();

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);

        address recipient = deployer; // default to signer address
        _execute(env, pk, deployer, amountLD, recipient, maxBpsToSponsor, finalToken);
    }

    /// @notice Run with an explicit finalRecipient, and custom sponsorship and finalToken (swap) configuration.
    function run(
        string memory tokenName,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        address finalToken
    ) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);
        DepositEnv memory env = _resolveEnv();

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0);
        address deployer = vm.addr(pk);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        _execute(env, pk, deployer, amountLD, recipient, maxBpsToSponsor, finalToken);
    }

    function _execute(
        DepositEnv memory env,
        uint256 deployerPrivateKey,
        address deployer,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        address finalToken
    ) private {
        SponsoredOFTSrcPeriphery srcPeripheryContract = SponsoredOFTSrcPeriphery(env.srcPeriphery);
        require(srcPeripheryContract.signer() == deployer, "quote signer mismatch");

        bytes32 nonce = bytes32(uint256(block.timestamp));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 maxUserSlippageBps = 200; // 2%
        uint256 lzReceiveGasLimit = 200_000;
        uint256 lzComposeGasLimit = 300_000;
        address refundRecipient = deployer;

        SignedQuoteParams memory signedParams = SignedQuoteParams({
            srcEid: env.srcEid,
            dstEid: env.dstEid,
            destinationHandler: env.destinationHandler.toBytes32(),
            amountLD: amountLD,
            nonce: nonce,
            deadline: deadline,
            maxBpsToSponsor: maxBpsToSponsor,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalToken.toBytes32(),
            lzReceiveGasLimit: lzReceiveGasLimit,
            lzComposeGasLimit: lzComposeGasLimit,
            executionMode: 0,
            actionData: ""
        });

        UnsignedQuoteParams memory unsignedParams = UnsignedQuoteParams({
            refundRecipient: refundRecipient,
            maxUserSlippageBps: maxUserSlippageBps
        });

        Quote memory quote = Quote({ signedParams: signedParams, unsignedParams: unsignedParams });

        bytes memory signature = DebugQuoteSignLib.signMemory(vm, deployerPrivateKey, signedParams);

        MessagingFee memory fee = _quoteMessagingFee(srcPeripheryContract, quote);

        vm.startBroadcast(deployerPrivateKey);
        IERC20(env.token).forceApprove(address(srcPeripheryContract), amountLD);
        srcPeripheryContract.deposit{ value: fee.nativeFee }(quote, signature);
        vm.stopBroadcast();
    }

    function _resolveEnv() internal returns (DepositEnv memory env) {
        uint256 srcChainId = block.chainid;
        uint256 srcForkId = forkOf[srcChainId];
        require(srcForkId != 0, "src chain not in config");
        vm.selectFork(srcForkId);

        env.srcPeriphery = config.get("src_periphery").toAddress();
        env.token = config.get("token").toAddress();
        require(env.srcPeriphery != address(0) && env.token != address(0), "missing src config");

        // Resolve srcEid from the messenger endpoint
        address srcMessenger = SponsoredOFTSrcPeriphery(env.srcPeriphery).OFT_MESSENGER();
        env.srcEid = IOAppCore(srcMessenger).endpoint().eid();

        // Always use HyperEVM as destination for local testing
        uint256 dstChainId = 999;
        uint256 dstForkId = forkOf[dstChainId];
        require(dstForkId != 0, "dst chain not in config");
        vm.selectFork(dstForkId);

        env.destinationHandler = config.get("dst_handler").toAddress();
        env.dstToken = config.get("token").toAddress();
        address dstMessenger = config.get("oft_messenger").toAddress();
        require(
            env.destinationHandler != address(0) && env.dstToken != address(0) && dstMessenger != address(0),
            "missing dst config"
        );
        env.dstEid = IOAppCore(dstMessenger).endpoint().eid();

        // Switch back to source fork for execution
        vm.selectFork(srcForkId);
    }

    function _quoteMessagingFee(
        SponsoredOFTSrcPeriphery srcPeripheryContract,
        Quote memory quote
    ) internal view returns (MessagingFee memory) {
        address oftMessenger = srcPeripheryContract.OFT_MESSENGER();

        bytes memory composeMsg = ComposeMsgCodec._encode(
            quote.signedParams.nonce,
            quote.signedParams.deadline,
            quote.signedParams.maxBpsToSponsor,
            quote.unsignedParams.maxUserSlippageBps,
            quote.signedParams.finalRecipient,
            quote.signedParams.finalToken,
            quote.signedParams.executionMode,
            quote.signedParams.actionData
        );

        bytes memory extraOptions = MinimalLZOptions
            .newOptions()
            .addExecutorLzReceiveOption(uint128(quote.signedParams.lzReceiveGasLimit), uint128(0))
            .addExecutorLzComposeOption(uint16(0), uint128(quote.signedParams.lzComposeGasLimit), uint128(0));

        SendParam memory sendParam = SendParam({
            dstEid: quote.signedParams.dstEid,
            to: quote.signedParams.destinationHandler,
            amountLD: quote.signedParams.amountLD,
            minAmountLD: quote.signedParams.amountLD,
            extraOptions: extraOptions,
            composeMsg: composeMsg,
            oftCmd: srcPeripheryContract.EMPTY_OFT_COMMAND()
        });

        return IOFT(oftMessenger).quoteSend(sendParam, false);
    }
}
