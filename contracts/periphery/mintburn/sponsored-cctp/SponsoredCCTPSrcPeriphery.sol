//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenMessengerV2 } from "../../../external/interfaces/CCTPInterfaces.sol";

import { SponsoredCCTPQuoteLib } from "../../../libraries/SponsoredCCTPQuoteLib.sol";
import { SponsoredCCTPInterface } from "../../../interfaces/SponsoredCCTPInterface.sol";

/**
 * @title SponsoredCCTPSrcPeriphery
 * @notice Source chain periphery contract that supports sponsored/non-sponsored CCTP deposits.
 * @dev This contract is used to deposit tokens for burn via CCTP.
 */
contract SponsoredCCTPSrcPeriphery is SponsoredCCTPInterface, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The CCTP token messenger contract.
    ITokenMessengerV2 public immutable cctpTokenMessenger;

    /// @notice The source domain ID for the chain that this contract is deployed on.
    uint32 public immutable sourceDomain;

    /// @notice The signer address that is used to validate the signatures of the quotes.
    address public signer;

    /// @notice A mapping of used nonces to prevent replay attacks.
    mapping(bytes32 => bool) public usedNonces;

    /**
     * @notice Constructor for the SponsoredCCTPSrcPeriphery contract.
     * @param _cctpTokenMessenger The address of the CCTP token messenger contract.
     * @param _sourceDomain The source domain ID for the chain that this contract is deployed on.
     * @param _signer The signer address that is used to validate the signatures of the quotes.
     */
    constructor(address _cctpTokenMessenger, uint32 _sourceDomain, address _signer) {
        cctpTokenMessenger = ITokenMessengerV2(_cctpTokenMessenger);
        sourceDomain = _sourceDomain;
        signer = _signer;
    }

    /**
     * @notice Deposits tokens for burn via CCTP.
     * @param quote The quote that contains the data for the deposit.
     * @param signature The signature of the quote.
     */
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external {
        if (!SponsoredCCTPQuoteLib.validateSignature(signer, quote, signature)) revert InvalidSignature();
        if (usedNonces[quote.nonce]) revert InvalidNonce();
        if (quote.deadline < block.timestamp) revert InvalidDeadline();
        if (quote.sourceDomain != sourceDomain) revert InvalidSourceDomain();

        (
            uint256 amount,
            uint32 destinationDomain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destinationCaller,
            uint256 maxFee,
            uint32 minFinalityThreshold,
            bytes memory hookData
        ) = SponsoredCCTPQuoteLib.getDepositForBurnData(quote);

        usedNonces[quote.nonce] = true;

        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(burnToken).forceApprove(address(cctpTokenMessenger), amount);

        cctpTokenMessenger.depositForBurnWithHook(
            amount,
            destinationDomain,
            mintRecipient,
            burnToken,
            destinationCaller,
            maxFee,
            minFinalityThreshold,
            hookData
        );

        emit SponsoredDepositForBurn(
            quote.nonce,
            msg.sender,
            quote.finalRecipient,
            quote.deadline,
            quote.maxBpsToSponsor,
            quote.maxUserSlippageBps,
            quote.finalToken,
            signature
        );
    }

    /**
     * @notice Sets the signer address that is used to validate the signatures of the quotes.
     * @param _signer The new signer address.
     */
    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }
}
