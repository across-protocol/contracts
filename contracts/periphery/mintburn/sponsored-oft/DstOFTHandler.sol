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
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";

/// @notice Handler that receives funds from LZ system, checks authorizations(both against LZ system and src chain
/// sender), and forwards authorized params to the `_executeFlow` function
contract DstOFTHandler is ILayerZeroComposer, HyperCoreFlowExecutor {
    using ComposeMsgCodec for bytes;
    using Bytes32ToAddress for bytes32;

    /// @notice We expect bridge amount that comes through to this Handler to be 1:1 with the src send amount, and we
    /// require our src handler to ensure that it is. We don't sponsor extra bridge fees in this handler
    uint256 public constant EXTRA_FEES_TO_SPONSOR = 0;

    address public immutable oftEndpoint;
    address public immutable ioft;

    /// @notice A mapping used to validate an incoming message against a list of authorized src periphery contracts. In
    /// bytes32 to support non-EVM src chains
    mapping(uint64 eid => bytes32 authorizedSrcPeriphery) authorizedSrcPeripheryContracts;

    /// @notice A mapping used for nonce uniqueness checks. Our src periphery and LZ should have prevented this already,
    /// but I guess better safe than sorry
    mapping(bytes32 quoteNonce => bool used) usedNonces;

    /// @notice Emitted when trying to call lzCompose from a source periphery that's not been configured in
    /// `authorizedSrcPeripheryContracts`
    error AuthorizedPeripheryNotSet(uint32 _srcEid);

    constructor(
        address _oftEndpoint,
        address _ioft,
        address _donationBox,
        address _baseToken,
        uint32 _coreIndex,
        bool _canBeUsedForAccountActivation,
        uint64 _accountActivationFeeCore,
        uint64 _bridgeSafetyBufferCore
    )
        HyperCoreFlowExecutor(
            _donationBox,
            _baseToken,
            _coreIndex,
            _canBeUsedForAccountActivation,
            _accountActivationFeeCore,
            _bridgeSafetyBufferCore
        )
    {
        // baseToken is assigned on `HyperCoreFlowExecutor` creation
        require(baseToken == IOFT(_ioft).token(), "IOFT doesn't match the baseToken");

        oftEndpoint = _oftEndpoint;
        ioft = _ioft;
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
        require(_oApp == ioft, "Invalid OApp");
        require(msg.sender == oftEndpoint, "Unauthorized endpoint sender");
        _requireAuthorizedPeriphery(_message);

        // Decode the actual `composeMsg` payload to extract the recipient address
        bytes memory _composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // This check is a safety mechanism against blackholing funds. The funds were sent by the authorized periphery
        // contract, but if the length is unexpected, we require funds be rescued, this is not a situation we aim to
        // revover from in `lzCompose` call
        require(_composeMsg._isValidComposeMsgBytelength(), "_composeMsg incorrectly formatted");

        bytes32 quoteNonce = _composeMsg._getNonce();
        require(!usedNonces[quoteNonce], "Nonce already used");
        usedNonces[quoteNonce] = true;

        address finalRecipient = _composeMsg._getFinalRecipient().toAddress();
        address finalToken = _composeMsg._getFinalToken().toAddress();
        uint256 maxBpsToSponsor = _composeMsg._getMaxBpsToSponsor();
        uint256 maxUserSlippageBps = _composeMsg._getMaxUserSlippageBps();
        uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);

        _executeFlow(
            _amountLD,
            quoteNonce,
            maxBpsToSponsor,
            maxUserSlippageBps,
            finalRecipient,
            finalToken,
            EXTRA_FEES_TO_SPONSOR
        );
    }

    /// @dev Checks that _message came from the authorized src periphery contract stored in `authorizedSrcPeripheryContracts`
    function _requireAuthorizedPeriphery(bytes calldata _message) internal view {
        uint32 _srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes32 authorizedPeriphery = authorizedSrcPeripheryContracts[_srcEid];
        if (authorizedPeriphery == bytes32(0)) {
            revert AuthorizedPeripheryNotSet(_srcEid);
        }

        // Decode original sender
        bytes32 _composeFromBytes32 = OFTComposeMsgCodec.composeFrom(_message);

        // We don't allow arbitrary src chain callers. If such a caller does send a message to this handler, the funds
        // will remain in this contract and will have to be rescued by an admin rescue function
        require(authorizedPeriphery == _composeFromBytes32, "Src periphery not authorized");
    }
}
