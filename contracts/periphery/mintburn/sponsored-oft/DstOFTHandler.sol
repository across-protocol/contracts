// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ILayerZeroComposer } from "../../../external/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "../../../libraries/OFTComposeMsgCodec.sol";
import { DonationBox } from "../../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../../libraries/HyperCoreLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";

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

contract DstOFTHandler is ILayerZeroComposer {
    address public immutable USDT0;
    address public immutable USDC;
    address public immutable USDH;

    address public immutable endpoint;
    address public immutable oApp;

    // @dev `donationBox` holds the funds we use for sponsorship. It serves as a convenient separator for user funds /
    // sponsorship funds
    DonationBox public immutable donationBox;

    // TODO? Is this the best way to authorize an OFT transfer?
    // TODO: currently, one per src chain. Is that fine?
    // @dev This will only work for EVM senders. We don't support SVM senders for OFT at this point
    mapping(uint64 => address) authorizedSrcPeripheryContracts;

    struct TokenInfo {
        bool canBeUsedForAccountCreationFee;
        uint256 accountCreationAmount; // depends on decimals?
    }

    // TODO: some tokenInfo mapping here .. Look in HyperCoreLib
    mapping(address => TokenInfo) tokens;

    error AuthorizedPeripheryNotSet(uint32 _srcEid);

    constructor(address _endpoint, address _oApp) {
        endpoint = _endpoint;
        oApp = _oApp;
        donationBox = new DonationBox();
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
        require(_oApp == oApp, "ComposedReceiver: Invalid OApp");
        require(msg.sender == endpoint, "ComposedReceiver: Unauthorized sender");
        _requireAuthorizedPeriphery(_message);

        // Decode the actual `composeMsg` payload to extract the recipient address
        bytes memory _composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // TODO: here, we could limit admin's powers by recording the amount as `unclaimedAmount` and only allowing the
        // admin to withdraw up to that amount. Nice-to-have IMO but not a req.
        // @dev If `_composeMsg` is not formatted the way we expect, just revert this call instead of potentially
        // blackholing the money. If the funds landed into this Handler, they'll have to be rescued via _adminRescueERC20()
        require(ComposeMsgCodec._isValidComposeMsgBytelength(_composeMsg), "_composeMsg incorrectly formatted");

        // TODO:
        // - finalToken == USDT0? send to HCore to user
        // - else, start swap flow ..

        // Decode the amount in local decimals being transferred
        // uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);
    }

    // TODO: what token to return this `amount` in? we can return USDC first. `finalToken` should also be Okay ...
    // TODO: perhaps rely on some quote params here
    function _estimateBridgeSponsorshipAmount(
        address finalUser,
        address finalToken
    ) internal returns (bool needsSponsorship, uint256 amount) {
        bool userHasHCoreAccount = HyperCoreLib.coreUserExists(finalUser);
        if (!userHasHCoreAccount) {
            TokenInfo memory token = tokens[finalToken];
            require(token.canBeUsedForAccountCreationFee, "wrong account creation fee token");
            return (true, token.accountCreationAmount);
        } else {
            return (false, 0);
        }
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
}
