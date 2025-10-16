// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ILayerZeroComposer } from "../../../external/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "../../../libraries/OFTComposeMsgCodec.sol";
import { DonationBox } from "../../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../../libraries/HyperCoreLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { IOFT } from "../../../interfaces/IOFT.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

// Contract to hold funds for swaps. We have one SwapHandler per finalToken. Used for separation of funds for different
// flows
contract SwapHandler {
    address public immutable parentHandler;

    constructor() {
        parentHandler = msg.sender;
    }

    modifier onlyParentHandler() {
        require(msg.sender == parentHandler, "Not parent handler");
        _;
    }

    // TODO: all the functions for interactions with `HyperCoreLib` that we might want
}

contract DstOFTHandler is ILayerZeroComposer, AccessControl {
    using ComposeMsgCodec for bytes;
    using Bytes32ToAddress for bytes32;

    // Roles
    bytes32 public constant LIMIT_ORDER_UPDATER_ROLE = keccak256("LIMIT_ORDER_UPDATER_ROLE");

    address public immutable endpoint;
    address public immutable oft;
    address public immutable oftToken;

    // TODO: if finalToken of a TX cannot be used as a fee token for account creation, use this tokens
    // TODO: make settable
    address public fallbackSponsorshipToken;
    // @dev Only these tokens are allowed to be a finalToken of the swap flow
    mapping(address => bool) public registeredFinalTokens;

    // @dev `donationBox` holds the funds we use for sponsorship. It serves as a convenient separator for user funds /
    // sponsorship funds
    DonationBox public immutable donationBox;

    // TODO? Is this the best way to authorize an OFT transfer?
    // TODO: currently, one per src chain. Is that fine?
    // @dev This will only work for EVM senders. We don't support SVM senders for OFT at this point
    mapping(uint64 => address) authorizedSrcPeripheryContracts;

    mapping(bytes32 => bool) quoteNonces;

    struct TokenInfo {
        HyperCoreLib.TokenInfo tokenInfo;
        uint32 hCoreTokenIndex;
        bool canBeUsedForAccountCreationFee;
        uint256 accountCreationAmount; // @dev in EVM wei
    }

    // @dev evmTokenAddress => TokenInfo
    mapping(address => TokenInfo) tokens;

    // @dev finalTokenEvmAddress => swapHandler. Used to isolate swap actions to different accounts
    mapping(address => SwapHandler) swapHandlers;

    error AuthorizedPeripheryNotSet(uint32 _srcEid);

    event FallbackSponsorshipTokenSet(address evmTokenAddress);
    event FinalTokenRegistered(address evmTokenAddress);
    event SimpleHcoreTransfer(
        bytes32 quoteNonce,
        uint256 amount,
        uint256 sponsoredAmount,
        address finalUser,
        address finalToken
    );

    // TODO: on construction, we should populate the `tokens` mapping with at least info about the USDT0
    // TODO: then we should have a function like `addAuthorizedFinalToken` that will add a token to the tokens
    constructor(
        address _endpoint,
        address _oft,
        address _oftToken,
        uint32 _oftTokenHCoreId,
        bool _canBeUsedForAccountCreationFee,
        uint256 _sponsorAmountWei
    ) {
        require(_oftToken == IOFT(_oft).token(), "oft, oftToken mistmatch");

        HyperCoreLib.TokenInfo memory tokenInfo = _getTokenInfoChecked(_oftToken, _oftTokenHCoreId);
        tokens[_oftToken] = TokenInfo(tokenInfo, _oftTokenHCoreId, _canBeUsedForAccountCreationFee, _sponsorAmountWei);

        endpoint = _endpoint;
        oft = _oft;
        oftToken = _oftToken;
        donationBox = new DonationBox();

        // AccessControl setup
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(LIMIT_ORDER_UPDATER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not default admin");
        _;
    }

    modifier onlyExistingToken(address evmTokenAddress) {
        // TODO: does this work?
        require(tokens[evmTokenAddress].tokenInfo.evmContract != address(0), "Unknown token");
        _;
    }

    function updateTokenInfo(
        address evmTokenAddress,
        uint32 hCoreTokenIndex,
        bool canBeUsedForAccountCreationFee,
        uint256 sponsorAmountWei
    ) external onlyDefaultAdmin {
        _updateTokenInfo(evmTokenAddress, hCoreTokenIndex, canBeUsedForAccountCreationFee, sponsorAmountWei);
    }

    function setFallbackSponsorshipToken(
        address evmTokenAddress
    ) external onlyDefaultAdmin onlyExistingToken(evmTokenAddress) {
        require(tokens[evmTokenAddress].canBeUsedForAccountCreationFee, "canBeUsedForAccountCreationFee = false");
        fallbackSponsorshipToken = evmTokenAddress;
    }

    // @dev config admin calls this function to add support for an additional token that can be a final token of swap flow
    function registerNewFinalToken(
        address evmTokenAddress
    ) external onlyDefaultAdmin onlyExistingToken(evmTokenAddress) {
        // TODO: there has to be some unregister call too. But we then have to have the ability to withdraw all tokens form the SwapHandler ...
        require(registeredFinalTokens[evmTokenAddress] == false, "Already registered");
        // TODO! Create a new SwapHandler contract
        registeredFinalTokens[evmTokenAddress] = true;
    }

    /**
     * @notice Handles incoming composed messages from LayerZero.
     * @dev Ensures the message comes from the correct OApp and is sent through the authorized endpoint.
     *
     * @param _oApp The address of the OApp that is sending the composed message.
     */
    function lzCompose(
        address _oApp,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override {
        require(_oApp == oft, "ComposedReceiver: Invalid OApp");
        require(msg.sender == endpoint, "ComposedReceiver: Unauthorized sender");
        _requireAuthorizedPeriphery(_message);

        // Decode the actual `composeMsg` payload to extract the recipient address
        bytes memory _composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // TODO: here, we could limit admin's powers by recording the amount as `unclaimedAmount` and only allowing the
        // admin to withdraw up to that amount. Nice-to-have IMO but not a req.
        // @dev If `_composeMsg` is not formatted the way we expect, just revert this call instead of potentially
        // blackholing the money. If the funds landed into this Handler, they'll have to be rescued via _adminRescueERC20()
        require(_composeMsg._isValidComposeMsgBytelength(), "_composeMsg incorrectly formatted");

        bytes32 quoteNonce = _composeMsg._getNonce();
        require(!quoteNonces[quoteNonce], "Nonce already used");
        quoteNonces[quoteNonce] = true;

        address finalRecipient = _composeMsg._getFinalRecipient().toAddress();
        address finalToken = _composeMsg._getFinalToken().toAddress();
        uint256 maxBpsToSponsor = _composeMsg._getMaxBpsToSponsor();
        if (finalToken == oftToken) {
            uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);
            _executeSimpleHCoreTransferFlow(_amountLD, quoteNonce, maxBpsToSponsor, finalRecipient, finalToken);
        } else {
            _initializeSwapFlow();
        }
    }

    function _executeSimpleHCoreTransferFlow(
        uint256 amountLD,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalUser,
        address finalToken
    ) internal {
        TokenInfo memory oftTokenInfo = tokens[oftToken];

        bool userHasHCoreAccount = HyperCoreLib.coreUserExists(finalUser);

        // TODO? Consider including fallbackSponsorshipToken logic in here. We'd need to send the 1 of fallback token
        // first and then the next transfer second: it's unclear whether or not HCore would respect submission order
        uint256 amountToSponsor = 0;
        // @dev If we're able to sponsor the user account creation in the `oftToken` and the account creation fee is
        // less than max fee we're willing to pay, sponsor account creation
        if (!userHasHCoreAccount && oftTokenInfo.canBeUsedForAccountCreationFee) {
            uint256 maxAmtToSponsor = (amountLD * maxBpsToSponsor) / 10_000;
            uint256 sponsorAmtRequired = oftTokenInfo.accountCreationAmount;
            if (maxAmtToSponsor <= sponsorAmtRequired) {
                amountToSponsor = sponsorAmtRequired;
            }
            // TODO: try to pull sponsored amount from donation box. emit event if DonationBox doesn't have the tokens.
        }

        HyperCoreLib.transferERC20EVMToCore(
            oftTokenInfo.tokenInfo.evmContract,
            oftTokenInfo.hCoreTokenIndex,
            finalUser,
            amountLD + amountToSponsor,
            oftTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleHcoreTransfer(quoteNonce, amountLD, amountToSponsor, finalUser, finalToken);
    }

    function _initializeSwapFlow() internal {
        // TODO! :D
    }

    // @dev Checks that _message came from the authorized src periphery contract stored in `authorizedSrcPeripheryContracts`
    function _requireAuthorizedPeriphery(bytes calldata _message) internal view {
        // Decode the source endpoint ID (originating chain)
        uint32 _srcEid = OFTComposeMsgCodec.srcEid(_message);
        address authorizedPeriphery = authorizedSrcPeripheryContracts[_srcEid];
        if (authorizedPeriphery == address(0)) {
            revert AuthorizedPeripheryNotSet(_srcEid);
        }

        // Decode the `composeFrom` address (original sender) from bytes32 to address
        bytes32 _composeFromBytes = OFTComposeMsgCodec.composeFrom(_message);

        // @dev This will only work for EVM senders. We don't support SVM senders for OFT at this point
        address _composeFrom = OFTComposeMsgCodec.bytes32ToAddress(_composeFromBytes);
        // @dev If the message is not from the authorized periphery contract, we cannot ensure the shape of _composeMsg
        // @dev _composeMsg is where the `finalRecipient` resides. These funds have to be rescued via _adminRescueERC20()
        require(authorizedPeriphery == _composeFrom, "Src periphery not authorized");
    }

    // Internal functions

    function _updateTokenInfo(
        address evmTokenAddress,
        uint32 hCoreTokenIndex,
        bool canBeUsedForAccountCreationFee,
        uint256 sponsorAmountWei
    ) internal {
        HyperCoreLib.TokenInfo memory tokenInfo = _getTokenInfoChecked(evmTokenAddress, hCoreTokenIndex);
        tokens[evmTokenAddress] = TokenInfo(
            tokenInfo,
            hCoreTokenIndex,
            canBeUsedForAccountCreationFee,
            sponsorAmountWei
        );
        // @dev if we're updating token info for a current `fallbackSponsorshipToken`, make sure that `canBeUsedForAccountCreationFee`
        // stays true. Otherwise, unset `fallbackSponsorshipToken`
        if (evmTokenAddress == fallbackSponsorshipToken && !tokens[evmTokenAddress].canBeUsedForAccountCreationFee) {
            fallbackSponsorshipToken = address(0);
        }
    }

    function _getTokenInfoChecked(
        address evmTokenAddress,
        uint32 hcoreTokenIndex
    ) internal view returns (HyperCoreLib.TokenInfo memory tokenInfo) {
        tokenInfo = HyperCoreLib.tokenInfo(hcoreTokenIndex);
        require(tokenInfo.evmContract == evmTokenAddress, "Wrong token id");
    }
}
