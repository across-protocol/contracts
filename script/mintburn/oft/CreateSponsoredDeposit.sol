// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../../../contracts/periphery/mintburn/sponsored-oft/Structs.sol";
import { AddressToBytes32 } from "../../../contracts/libraries/AddressConverters.sol";
import { ComposeMsgCodec } from "../../../contracts/periphery/mintburn/sponsored-oft/ComposeMsgCodec.sol";
import { MinimalLZOptions } from "../../../contracts/external/libraries/MinimalLZOptions.sol";
import { IOFT, SendParam, MessagingFee } from "../../../contracts/interfaces/IOFT.sol";
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

// forge script script/mintburn/oft/CreateSponsoredDeposit.sol:CreateSponsoredDeposit --rpc-url arbitrum -vvvv
contract CreateSponsoredDeposit is Script {
    using AddressToBytes32 for address;
    using SafeERC20 for IERC20;
    using MinimalLZOptions for bytes;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey); // dev wallet

        // --- START CONFIG ---
        uint32 srcEid = 30110; // Arbitrum
        address srcPeriphery = 0x1235Ac1010FeeC8ae22744f323416cBBE37feDbE;
        address token = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // Arbitrum USDT
        uint256 amountLD = 1 * 10 ** 6 + 5456; // 1 USDT (6 decimals)
        bytes32 nonce = bytes32(uint256(12353)); // Replace with unique nonce per deposit
        uint256 deadline = block.timestamp + 1 hours;
        uint256 maxBpsToSponsor = 100; // 1%
        uint256 maxUserSlippageBps = 50; // 0.5%
        uint32 dstEid = 30367; // HyperEVM
        address destinationHandler = 0x1425e20d2EcB0bbDEeD8fe1F8252724ED084c1A0;
        address finalRecipient = 0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D; // alternative dev wallet
        address finalToken = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb; // USDT0 @ HyperEVM
        uint256 lzReceiveGasLimit = 200_000;
        uint256 lzComposeGasLimit = 300_000;
        address refundRecipient = deployer; // dev wallet
        // --- END CONFIG ---

        SponsoredOFTSrcPeriphery srcPeripheryContract = SponsoredOFTSrcPeriphery(srcPeriphery);
        require(srcPeripheryContract.signer() == deployer, "quote signer mismatch");

        SignedQuoteParams memory signedParams = SignedQuoteParams({
            srcEid: srcEid,
            dstEid: dstEid,
            destinationHandler: destinationHandler.toBytes32(),
            amountLD: amountLD,
            nonce: nonce,
            deadline: deadline,
            maxBpsToSponsor: maxBpsToSponsor,
            finalRecipient: finalRecipient.toBytes32(),
            finalToken: finalToken.toBytes32(),
            lzReceiveGasLimit: lzReceiveGasLimit,
            lzComposeGasLimit: lzComposeGasLimit,
            executionMode: 0, // DirectToCore mode
            actionData: "" // Empty for DirectToCore mode
        });

        UnsignedQuoteParams memory unsignedParams = UnsignedQuoteParams({
            refundRecipient: refundRecipient,
            maxUserSlippageBps: maxUserSlippageBps
        });

        Quote memory quote = Quote({ signedParams: signedParams, unsignedParams: unsignedParams });

        bytes32 quoteDigest = DebugQuoteSignLib.hashMemory(signedParams);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(deployerPrivateKey, quoteDigest);
        bytes memory signature = abi.encodePacked(r, s, v);

        MessagingFee memory fee = _quoteMessagingFee(srcPeripheryContract, quote);

        vm.startBroadcast(deployerPrivateKey);

        IERC20(token).forceApprove(srcPeriphery, amountLD);

        srcPeripheryContract.deposit{ value: fee.nativeFee }(quote, signature);

        vm.stopBroadcast();
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
