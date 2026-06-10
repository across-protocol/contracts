// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { SponsoredOFTInterface } from "../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { SponsoredExecutionModeInterface } from "../../../contracts/interfaces/SponsoredExecutionModeInterface.sol";
import { ArbitraryEVMFlowExecutor } from "../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { ComposeMsgCodec } from "../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";
import { MinimalLZOptions } from "../../../contracts/external/libraries/MinimalLZOptions.sol";
import { IOFT, SendParam, MessagingFee, IOAppCore, IEndpoint } from "../../../contracts/interfaces/IOFT.sol";
import { HyperCoreLib } from "../../../contracts/libraries/HyperCoreLib.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Used in place of // import { QuoteSignLib } from "../contracts/periphery/mintburn/sponsored-oft/QuoteSignLib.sol";
/// just for the hashing function that works with a memory function argument
library DebugQuoteSignLib {
    /// @notice Compute the keccak of all `SignedQuoteParams` fields. Accept memory arg
    function hashMemory(SponsoredOFTInterface.SignedQuoteParams memory p) internal pure returns (bytes32) {
        bytes32 hash1 = keccak256(
            abi.encode(
                p.srcEid,
                p.dstEid,
                p.destinationHandler,
                p.amountLD,
                p.nonce,
                p.deadline,
                p.maxBpsToSponsor,
                p.maxUserSlippageBps,
                p.finalRecipient
            )
        );

        bytes32 hash2 = keccak256(
            abi.encode(
                p.finalToken,
                p.destinationDex,
                p.lzReceiveGasLimit,
                p.lzComposeGasLimit,
                p.maxOftFeeBps,
                p.accountCreationMode,
                p.executionMode,
                keccak256(p.actionData) // Hash the actionData to keep signature size reasonable
            )
        );

        return keccak256(abi.encode(hash1, hash2));
    }

    /// @notice Sign the quote using Foundry's Vm cheatcode and return concatenated bytes signature (r,s,v).
    function signMemory(
        Vm vm,
        uint256 pk,
        SponsoredOFTInterface.SignedQuoteParams memory p
    ) internal pure returns (bytes memory) {
        bytes32 digest = hashMemory(p);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}

/*
The `uint32 dstEid` arg selects the LayerZero destination: pass 0 to default to HyperEVM (chain 999),
or a specific endpoint id to route to the configured chain whose OFT messenger reports that eid.
The trailing `bool showCast` arg prints a copy/paste cast command and skips the broadcast when true.

- Simple transfer (no swap), sponsored (e.g. 1%), default dst (HyperEVM):
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,uint32,bool)" usdt0 1000000 100 0 false --rpc-url arbitrum -vvvv

- Simple transfer (no swap), non-sponsored, explicit dst eid:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,uint32,bool)" usdt0 1000000 0 30367 false --rpc-url arbitrum -vvvv

- Simple transfer (no swap) with explicit recipient, sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256,uint32,bool)" usdt0 1000000 0xRecipient 100 0 false --rpc-url arbitrum -vvvv

- Simple transfer (no swap) with explicit recipient, non-sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256,uint32,bool)" usdt0 1000000 0xRecipient 0 0 false --rpc-url arbitrum -vvvv

- Swap flow (finalToken specified), sponsored (e.g. 1%):
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,address,uint32,bool)" usdt0 1000000 100 0xFinalToken 0 false --rpc-url arbitrum -vvvv

- Swap flow (finalToken specified), non-sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,address,uint32,bool)" usdt0 1000000 0 0xFinalToken 0 false --rpc-url arbitrum -vvvv

- Swap flow with explicit recipient, sponsored:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,address,uint256,address,uint32,bool)" usdt0 1000000 0xRecipient 100 0xFinalToken 0 false --rpc-url arbitrum -vvvv

- Account creation from user funds with explicit recipient:
  USER=0xRecipient
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "runFromUserFunds(string,uint256,address,uint256,uint32,bool)" usdt0 1000000 $USER 0 0 false --rpc-url arbitrum -vvvv

- Arbitrary actions on the destination (executionMode 1 = ArbitraryActionsToCore, 2 = ArbitraryActionsToEVM).
  `actionData` is an abi-encoded ArbitraryEVMFlowExecutor.CompressedCall[]; pass 0x for an empty call array:
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "runArbitrary(string,uint256,address,uint256,address,uint8,bytes,uint32,bool)" \
    usdt0 1000000 0xRecipient 100 0xFinalToken 1 0xACTION_DATA 0 false --rpc-url arbitrum -vvvv

- Print cast command instead of sending (use --rpc-url to fork-quote the LZ fee):
  forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
    --sig "run(string,uint256,uint256,uint32,bool)" usdt0 1000000 100 0 true --rpc-url arbitrum -vvvv
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

    uint8 internal constant ACCOUNT_CREATION_STANDARD = 0;
    uint8 internal constant ACCOUNT_CREATION_FROM_USER_FUNDS = 1;
    uint8 internal constant EXECUTION_MODE_DIRECT_TO_CORE = 0;
    uint8 internal constant EXECUTION_MODE_ARBITRARY_TO_CORE = 1;
    uint8 internal constant EXECUTION_MODE_ARBITRARY_TO_EVM = 2;

    function run() external pure {
        revert("see header for supported run signatures");
    }

    function run(string memory) external pure {
        revert("see header for supported run signatures");
    }

    /// @notice Shared setup: load the token's TOML, resolve the src/dst environment, and derive the signer.
    function _prepare(
        string memory tokenName,
        uint32 dstEid
    ) private returns (DepositEnv memory env, uint256 pk, address deployer) {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        _loadConfigAndForks(configPath, false);
        env = _resolveEnv(dstEid);

        pk = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        deployer = vm.addr(pk);
    }

    /// @notice Simple transfer entrypoint: finalToken defaults to the input token from config, recipient defaults to signer.
    function run(
        string memory tokenName,
        uint256 amountLD,
        uint256 maxBpsToSponsor,
        uint32 dstEid,
        bool showCast
    ) external {
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = deployer;
        address finalToken = env.dstToken; // default to destination token: simple transfer
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            finalToken,
            ACCOUNT_CREATION_STANDARD,
            EXECUTION_MODE_DIRECT_TO_CORE,
            "",
            showCast
        );
    }

    /// @notice Simple transfer entrypoint with explicit recipient (finalToken defaults to the input token).
    function run(
        string memory tokenName,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        uint32 dstEid,
        bool showCast
    ) external {
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        address finalToken = env.dstToken; // simple transfer uses destination token
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            finalToken,
            ACCOUNT_CREATION_STANDARD,
            EXECUTION_MODE_DIRECT_TO_CORE,
            "",
            showCast
        );
    }

    /// @notice Run with default finalRecipient = signer, and custom sponsorship and finalToken (swap) configuration.
    function run(
        string memory tokenName,
        uint256 amountLD,
        uint256 maxBpsToSponsor,
        address finalToken,
        uint32 dstEid,
        bool showCast
    ) external {
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = deployer; // default to signer address
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            finalToken,
            ACCOUNT_CREATION_STANDARD,
            EXECUTION_MODE_DIRECT_TO_CORE,
            "",
            showCast
        );
    }

    /// @notice Run with an explicit finalRecipient, and custom sponsorship and finalToken (swap) configuration.
    function run(
        string memory tokenName,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        address finalToken,
        uint32 dstEid,
        bool showCast
    ) external {
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            finalToken,
            ACCOUNT_CREATION_STANDARD,
            EXECUTION_MODE_DIRECT_TO_CORE,
            "",
            showCast
        );
    }

    /// @notice Run simple transfer in FromUserFunds mode with explicit recipient.
    function runFromUserFunds(
        string memory tokenName,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        uint32 dstEid,
        bool showCast
    ) external {
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            env.dstToken,
            ACCOUNT_CREATION_FROM_USER_FUNDS,
            EXECUTION_MODE_DIRECT_TO_CORE,
            "",
            showCast
        );
    }

    /// @notice Arbitrary execution mode (ArbitraryActionsToCore=1 or ArbitraryActionsToEVM=2) with action data.
    /// @dev `actionData` is an abi-encoded `ArbitraryEVMFlowExecutor.CompressedCall[]`; pass empty bytes to encode
    ///      a zero-length call array (e.g. an EVM-only transfer of the bridged token to the final recipient).
    function runArbitrary(
        string memory tokenName,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        address finalToken,
        uint8 executionMode,
        bytes memory actionData,
        uint32 dstEid,
        bool showCast
    ) external {
        require(
            executionMode == EXECUTION_MODE_ARBITRARY_TO_CORE || executionMode == EXECUTION_MODE_ARBITRARY_TO_EVM,
            "use run* for DirectToCore"
        );
        if (actionData.length == 0) {
            actionData = abi.encode(new ArbitraryEVMFlowExecutor.CompressedCall[](0));
        }
        (DepositEnv memory env, uint256 pk, address deployer) = _prepare(tokenName, dstEid);

        address recipient = finalRecipient == address(0) ? deployer : finalRecipient;
        _execute(
            env,
            pk,
            deployer,
            amountLD,
            recipient,
            maxBpsToSponsor,
            finalToken,
            ACCOUNT_CREATION_STANDARD,
            executionMode,
            actionData,
            showCast
        );
    }

    function _execute(
        DepositEnv memory env,
        uint256 deployerPrivateKey,
        address deployer,
        uint256 amountLD,
        address finalRecipient,
        uint256 maxBpsToSponsor,
        address finalToken,
        uint8 accountCreationMode,
        uint8 executionMode,
        bytes memory actionData,
        bool showCast
    ) private {
        require(accountCreationMode <= ACCOUNT_CREATION_FROM_USER_FUNDS, "invalid account mode");
        require(executionMode <= EXECUTION_MODE_ARBITRARY_TO_EVM, "invalid execution mode");
        SponsoredOFTSrcPeriphery srcPeripheryContract = SponsoredOFTSrcPeriphery(env.srcPeriphery);
        require(srcPeripheryContract.signer() == deployer, "quote signer mismatch");

        bytes32 nonce = bytes32(uint256(block.timestamp));
        uint256 deadline = block.timestamp + 1 hours;
        uint256 maxUserSlippageBps = 200; // 2%
        uint256 lzReceiveGasLimit = 200_000;
        uint256 lzComposeGasLimit = 300_000;
        address refundRecipient = deployer;

        SponsoredOFTInterface.SignedQuoteParams memory signedParams = SponsoredOFTInterface.SignedQuoteParams({
            srcEid: env.srcEid,
            dstEid: env.dstEid,
            destinationHandler: env.destinationHandler.toBytes32(),
            amountLD: amountLD,
            nonce: nonce,
            deadline: deadline,
            maxBpsToSponsor: maxBpsToSponsor,
            maxUserSlippageBps: maxUserSlippageBps,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalToken.toBytes32(),
            destinationDex: HyperCoreLib.CORE_SPOT_DEX_ID,
            lzReceiveGasLimit: lzReceiveGasLimit,
            lzComposeGasLimit: lzComposeGasLimit,
            maxOftFeeBps: 0,
            accountCreationMode: accountCreationMode,
            executionMode: executionMode,
            actionData: actionData
        });

        SponsoredOFTInterface.UnsignedQuoteParams memory unsignedParams = SponsoredOFTInterface.UnsignedQuoteParams({
            refundRecipient: refundRecipient
        });

        SponsoredOFTInterface.Quote memory quote = SponsoredOFTInterface.Quote({
            signedParams: signedParams,
            unsignedParams: unsignedParams
        });

        bytes memory signature = DebugQuoteSignLib.signMemory(vm, deployerPrivateKey, signedParams);

        // Same-chain (direct) flow: the src periphery skips the OFT bridge entirely and
        // requires msg.value == 0, so don't call quoteSend on the OFT messenger.
        MessagingFee memory fee;
        if (env.srcEid != env.dstEid) {
            fee = _quoteMessagingFee(srcPeripheryContract, quote);
        }

        if (showCast) {
            _logCastCommand(address(srcPeripheryContract), quote, signature, fee.nativeFee);
            return;
        }

        vm.startBroadcast(deployerPrivateKey);
        IERC20(env.token).forceApprove(address(srcPeripheryContract), amountLD);
        srcPeripheryContract.deposit{ value: fee.nativeFee }(quote, signature);
        vm.stopBroadcast();
    }

    function _logCastCommand(
        address target,
        SponsoredOFTInterface.Quote memory quote,
        bytes memory signature,
        uint256 nativeFee
    ) private view {
        SponsoredOFTInterface.SignedQuoteParams memory s = quote.signedParams;

        string memory signedTuple = string.concat(
            "(",
            vm.toString(uint256(s.srcEid)),
            ",",
            vm.toString(uint256(s.dstEid)),
            ",",
            vm.toString(s.destinationHandler),
            ",",
            vm.toString(s.amountLD),
            ",",
            vm.toString(s.nonce),
            ",",
            vm.toString(s.deadline),
            ","
        );
        signedTuple = string.concat(
            signedTuple,
            vm.toString(s.maxBpsToSponsor),
            ",",
            vm.toString(s.maxUserSlippageBps),
            ",",
            vm.toString(s.finalRecipient),
            ",",
            vm.toString(s.finalToken),
            ",",
            vm.toString(uint256(s.destinationDex)),
            ","
        );
        signedTuple = string.concat(
            signedTuple,
            vm.toString(s.lzReceiveGasLimit),
            ",",
            vm.toString(s.lzComposeGasLimit),
            ",",
            vm.toString(s.maxOftFeeBps),
            ",",
            vm.toString(uint256(s.accountCreationMode)),
            ",",
            vm.toString(uint256(s.executionMode)),
            ",",
            vm.toString(s.actionData),
            ")"
        );

        string memory tuple = string.concat(
            "(",
            signedTuple,
            ",(",
            vm.toString(quote.unsignedParams.refundRecipient),
            "))"
        );

        string
            memory funcSig = "deposit(((uint32,uint32,bytes32,uint256,bytes32,uint256,uint256,uint256,bytes32,bytes32,uint32,uint256,uint256,uint256,uint8,uint8,bytes),(address)),bytes)";

        string memory cmd = string.concat(
            "cast send ",
            vm.toString(target),
            " \\\n  '",
            funcSig,
            "' \\\n  '",
            tuple,
            "' \\\n  ",
            vm.toString(signature),
            " \\\n  --value ",
            vm.toString(nativeFee),
            " \\\n  --rpc-url <network> --account dev"
        );

        console.log("=== cast command (copy/paste; swap `cast send` for `cast call` to dry-run) ===");
        console.log(cmd);
        console.log("Note: caller must approve `token` to the src periphery for at least amountLD before sending.");
        console.log("=============================================================================");
    }

    /// @notice Resolve the source/destination environment for the deposit.
    /// @param dstEid LayerZero destination endpoint id. Pass 0 to default to HyperEVM (chain 999);
    ///        otherwise the configured chain whose OFT messenger endpoint reports this eid is used.
    function _resolveEnv(uint32 dstEid) internal returns (DepositEnv memory env) {
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

        // Default to HyperEVM (chain 999) when no dstEid is passed; otherwise reverse-map the eid.
        uint256 dstChainId = dstEid == 0 ? 999 : _chainIdForEid(dstEid);
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

    /// @notice Find the configured chain id whose OFT messenger endpoint reports `dstEid`.
    function _chainIdForEid(uint32 dstEid) internal returns (uint256) {
        uint256[] memory chainIds = config.getChainIds();
        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];
            uint256 forkId = forkOf[chainId];
            address messenger = config.get(chainId, "oft_messenger").toAddress();
            if (forkId == 0 || messenger == address(0)) continue;
            vm.selectFork(forkId);
            try IOAppCore(messenger).endpoint() returns (IEndpoint ep) {
                if (ep.eid() == dstEid) return chainId;
            } catch {}
        }
        revert("no configured chain matches dstEid");
    }

    function _quoteMessagingFee(
        SponsoredOFTSrcPeriphery srcPeripheryContract,
        SponsoredOFTInterface.Quote memory quote
    ) internal view returns (MessagingFee memory) {
        address oftMessenger = srcPeripheryContract.OFT_MESSENGER();
        uint64 amountSD = SafeCast.toUint64(quote.signedParams.amountLD / srcPeripheryContract.decimalConversionRate());

        bytes memory composeMsg = ComposeMsgCodec._encode(
            quote.signedParams.nonce,
            uint256(amountSD),
            quote.signedParams.maxBpsToSponsor,
            quote.signedParams.maxUserSlippageBps,
            quote.signedParams.finalRecipient,
            quote.signedParams.finalToken,
            quote.signedParams.destinationDex,
            quote.signedParams.accountCreationMode,
            quote.signedParams.executionMode,
            quote.signedParams.actionData
        );

        bytes memory extraOptions = MinimalLZOptions
            .newOptions()
            .addExecutorLzReceiveOption(uint128(quote.signedParams.lzReceiveGasLimit), uint128(0))
            .addExecutorLzComposeOption(uint16(0), uint128(quote.signedParams.lzComposeGasLimit), uint128(0));

        require(quote.signedParams.maxOftFeeBps <= 10_000, "maxOftFeeBps > 10000");
        uint256 minAmountLD = (quote.signedParams.amountLD * (10_000 - quote.signedParams.maxOftFeeBps)) / 10_000;

        SendParam memory sendParam = SendParam({
            dstEid: quote.signedParams.dstEid,
            to: quote.signedParams.destinationHandler,
            amountLD: quote.signedParams.amountLD,
            minAmountLD: minAmountLD,
            extraOptions: extraOptions,
            composeMsg: composeMsg,
            oftCmd: srcPeripheryContract.EMPTY_OFT_COMMAND()
        });

        return IOFT(oftMessenger).quoteSend(sendParam, false);
    }
}
