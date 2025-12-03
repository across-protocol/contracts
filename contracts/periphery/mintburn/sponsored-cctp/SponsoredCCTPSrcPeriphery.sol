//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
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

    /// @custom:storage-location erc7201:SponsoredCCTPSrcPeriphery.main
    struct MainStorage {
        /// @notice The signer address that is used to validate the signatures of the quotes.
        address signer;
        /// @notice A mapping of used nonces to prevent replay attacks.
        mapping(bytes32 => bool) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("erc7201:SponsoredCCTPSrcPeriphery.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MAIN_STORAGE_LOCATION = 0xf0a1b42b86a218bb35dbc2254545839ce4b1bf1d3780b5099e3e0abfc7a5b200;

    function _getMainStorage() private pure returns (MainStorage storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /**
     * @notice Constructor for the SponsoredCCTPSrcPeriphery contract.
     * @param _cctpTokenMessenger The address of the CCTP token messenger contract.
     * @param _sourceDomain The source domain ID for the chain that this contract is deployed on.
     * @param _signer The signer address that is used to validate the signatures of the quotes.
     */
    constructor(address _cctpTokenMessenger, uint32 _sourceDomain, address _signer) {
        cctpTokenMessenger = ITokenMessengerV2(_cctpTokenMessenger);
        sourceDomain = _sourceDomain;
        _getMainStorage().signer = _signer;
    }

    /**
     * @notice Returns the signer address that is used to validate the signatures of the quotes.
     * @return The signer address.
     */
    function signer() external view returns (address) {
        return _getMainStorage().signer;
    }

    /**
     * @notice Returns true if the nonce has been used, false otherwise.
     * @param nonce The nonce to check.
     * @return True if the nonce has been used, false otherwise.
     */
    function usedNonces(bytes32 nonce) external view returns (bool) {
        return _getMainStorage().usedNonces[nonce];
    }

    /**
     * @notice Deposits tokens for burn via CCTP.
     * @param quote The quote that contains the data for the deposit.
     * @param signature The signature of the quote.
     */
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external {
        MainStorage storage $ = _getMainStorage();
        if (!SponsoredCCTPQuoteLib.validateSignature($.signer, quote, signature)) revert InvalidSignature();
        if ($.usedNonces[quote.nonce]) revert InvalidNonce();
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

        $.usedNonces[quote.nonce] = true;

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
        _getMainStorage().signer = _signer;
    }
}
