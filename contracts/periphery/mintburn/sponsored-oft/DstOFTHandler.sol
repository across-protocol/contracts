// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { BaseModuleHandler } from "../BaseModuleHandler.sol";
import { ILayerZeroComposer } from "../../../external/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "../../../external/libraries/OFTComposeMsgCodec.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";
import { ExecutionMode } from "./Structs.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { IOFT, IOAppCore } from "../../../interfaces/IOFT.sol";
import { HyperCoreFlowExecutor } from "../HyperCoreFlowExecutor.sol";
import { ArbitraryEVMFlowExecutor } from "../ArbitraryEVMFlowExecutor.sol";
import { CommonFlowParams, EVMFlowParams } from "../Structs.sol";

import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Handler that receives funds from LZ system, checks authorizations(both against LZ system and src chain 
    sender), and forwards authorized params to the `_executeFlow` function
 * @dev IMPORTANT. `BaseModuleHandler` should always be the first contract in inheritance chain. Read 
    `BaseModuleHandler` contract code to learn more.
 */
contract DstOFTHandler is BaseModuleHandler, ILayerZeroComposer, ArbitraryEVMFlowExecutor {
    using ComposeMsgCodec for bytes;
    using Bytes32ToAddress for bytes32;
    using AddressToBytes32 for address;
    using SafeERC20 for IERC20;

    /// @notice We expect bridge amount that comes through to this Handler to be 1:1 with the src send amount, and we
    /// require our src handler to ensure that it is. We don't sponsor extra bridge fees in this handler
    uint256 public constant EXTRA_FEES_TO_SPONSOR = 0;

    address public immutable OFT_ENDPOINT_ADDRESS;
    address public immutable IOFT_ADDRESS;

    /// @notice Base token associated with this handler. The one we receive from the OFT bridge
    address public immutable baseToken;

    /// @custom:storage-location erc7201:DstOFTHandler.main
    struct MainStorage {
        /// @notice A mapping used to validate an incoming message against a list of authorized src periphery contracts. In
        /// bytes32 to support non-EVM src chains
        mapping(uint64 eid => bytes32 authorizedSrcPeriphery) authorizedSrcPeripheryContracts;
        /// @notice A mapping used for nonce uniqueness checks. Our src periphery and LZ should have prevented this already,
        /// but I guess better safe than sorry
        mapping(bytes32 quoteNonce => bool used) usedNonces;
    }

    // keccak256(abi.encode(uint256(keccak256("erc7201:DstOFTHandler.main")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MAIN_STORAGE_LOCATION = 0xe61a4c968926ec08fb0c5bf5be95077bf8b3ddd75ead66c94187ce8d5509de00;

    function _getMainStorage() private pure returns (MainStorage storage $) {
        assembly {
            $.slot := MAIN_STORAGE_LOCATION
        }
    }

    /**
     * @notice Emitted when a new authorized src periphery is configured
     * @param srcEid The source chain endpoint ID
     * @param srcPeriphery The authorized source periphery contract address (as bytes32)
     */
    event SetAuthorizedPeriphery(uint32 srcEid, bytes32 srcPeriphery);

    /// @notice Thrown when trying to call lzCompose from a source periphery that's not been configured in `authorizedSrcPeripheryContracts`
    error AuthorizedPeripheryNotSet(uint32 _srcEid);
    /// @notice Thrown when source chain recipient is not authorized periphery contract
    error UnauthorizedSrcPeriphery(uint32 _srcEid);
    /// @notice Thrown when the supplied token does not match the supplied ioft messenger
    error TokenIOFTMismatch();
    /// @notice Thrown when the supplied ioft address does not match the supplied endpoint address
    error IOFTEndpointMismatch();
    /// @notice Thrown if Quote nonce was already used
    error NonceAlreadyUsed();
    /// @notice Thrown if supplied OApp is not configured ioft
    error InvalidOApp();
    /// @notice Thrown if called by an unauthorized endpoint
    error UnauthorizedEndpoint();
    /// @notice Thrown when supplied _composeMsg format is unexpected
    error InvalidComposeMsgFormat();

    constructor(
        address _oftEndpoint,
        address _ioft,
        address _donationBox,
        address _baseToken,
        address _multicallHandler
    ) BaseModuleHandler(_donationBox, _baseToken, DEFAULT_ADMIN_ROLE) ArbitraryEVMFlowExecutor(_multicallHandler) {
        baseToken = _baseToken;

        if (_baseToken != IOFT(_ioft).token()) {
            revert TokenIOFTMismatch();
        }

        OFT_ENDPOINT_ADDRESS = _oftEndpoint;
        IOFT_ADDRESS = _ioft;
        if (address(IOAppCore(IOFT_ADDRESS).endpoint()) != address(OFT_ENDPOINT_ADDRESS)) {
            revert IOFTEndpointMismatch();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Returns the authorized src periphery contract for a given source chain endpoint ID.
     * @param srcEid The source chain endpoint ID
     * @return The authorized src periphery contract address (as bytes32)
     */
    function authorizedSrcPeripheryContracts(uint64 srcEid) external view returns (bytes32) {
        return _getMainStorage().authorizedSrcPeripheryContracts[srcEid];
    }

    /**
     * @notice Returns true if the nonce has been used, false otherwise.
     * @param nonce The nonce to check.
     * @return True if the nonce has been used, false otherwise.
     */
    function usedNonces(bytes32 nonce) external view returns (bool) {
        return _getMainStorage().usedNonces[nonce];
    }

    function setAuthorizedPeriphery(
        uint32 srcEid,
        bytes32 srcPeriphery
    ) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _getMainStorage().authorizedSrcPeripheryContracts[srcEid] = srcPeriphery;
        emit SetAuthorizedPeriphery(srcEid, srcPeriphery);
    }

    /**
     * @notice Handles incoming composed messages from LayerZero.
     * @dev Ensures the message comes from the correct OApp and is sent through the authorized endpoint.
     *
     * @param _oApp The address of the OApp that is sending the composed message.
     * @param _message The composed message payload containing transfer and execution details
     */
    function lzCompose(
        address _oApp,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override nonReentrant authorizeFundedFlow {
        _requireAuthorizedMessage(_oApp, _message);

        // Decode the actual `composeMsg` payload to extract the recipient address
        bytes memory composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // This check is a safety mechanism against blackholing funds. The funds were sent by the authorized periphery
        // contract, but if the length is unexpected, we require funds be rescued, this is not a situation we aim to
        // recover from in `lzCompose` call
        if (!composeMsg._isValidComposeMsgBytelength()) {
            revert InvalidComposeMsgFormat();
        }

        bytes32 quoteNonce = composeMsg._getNonce();
        MainStorage storage $ = _getMainStorage();
        if ($.usedNonces[quoteNonce]) {
            revert NonceAlreadyUsed();
        }
        $.usedNonces[quoteNonce] = true;

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        uint256 maxBpsToSponsor = composeMsg._getMaxBpsToSponsor();
        uint256 maxUserSlippageBps = composeMsg._getMaxUserSlippageBps();
        address finalRecipient = composeMsg._getFinalRecipient().toAddress();
        address finalToken = composeMsg._getFinalToken().toAddress();
        uint8 executionMode = composeMsg._getExecutionMode();
        bytes memory actionData = composeMsg._getActionData();

        CommonFlowParams memory commonParams = CommonFlowParams({
            amountInEVM: amountLD,
            quoteNonce: quoteNonce,
            finalRecipient: finalRecipient,
            finalToken: finalToken,
            maxBpsToSponsor: maxBpsToSponsor,
            extraFeesIncurred: EXTRA_FEES_TO_SPONSOR
        });

        // Route to appropriate execution based on executionMode
        if (
            executionMode == uint8(ExecutionMode.ArbitraryActionsToCore) ||
            executionMode == uint8(ExecutionMode.ArbitraryActionsToEVM)
        ) {
            // Execute flow with arbitrary evm actions
            _executeWithEVMFlow(
                EVMFlowParams({
                    commonParams: commonParams,
                    initialToken: baseToken,
                    actionData: actionData,
                    transferToCore: executionMode == uint8(ExecutionMode.ArbitraryActionsToCore)
                })
            );
        } else {
            // Execute standard HyperCore flow (default) via delegatecall
            _delegateToHyperCore(abi.encodeCall(HyperCoreFlowExecutor.executeFlow, (commonParams, maxUserSlippageBps)));
        }
    }

    function _executeWithEVMFlow(EVMFlowParams memory params) internal {
        params.commonParams = ArbitraryEVMFlowExecutor._executeFlow(params);

        // Route to appropriate destination based on transferToCore flag
        _delegateToHyperCore(
            params.transferToCore
                ? abi.encodeCall(HyperCoreFlowExecutor.executeSimpleTransferFlow, (params.commonParams))
                : abi.encodeCall(HyperCoreFlowExecutor.fallbackHyperEVMFlow, (params.commonParams))
        );
    }

    /// @notice Checks that message was authorized by LayerZero's identity system and that it came from authorized src periphery
    function _requireAuthorizedMessage(address _oApp, bytes calldata _message) internal view {
        if (_oApp != IOFT_ADDRESS) {
            revert InvalidOApp();
        }
        if (msg.sender != OFT_ENDPOINT_ADDRESS) {
            revert UnauthorizedEndpoint();
        }
        _requireAuthorizedPeriphery(_message);
    }

    /// @dev Checks that _message came from the authorized src periphery contract stored in `authorizedSrcPeripheryContracts`
    function _requireAuthorizedPeriphery(bytes calldata _message) internal view {
        uint32 _srcEid = OFTComposeMsgCodec.srcEid(_message);
        bytes32 authorizedPeriphery = _getMainStorage().authorizedSrcPeripheryContracts[_srcEid];
        if (authorizedPeriphery == bytes32(0)) {
            revert AuthorizedPeripheryNotSet(_srcEid);
        }

        // Decode original sender
        bytes32 _composeFromBytes32 = OFTComposeMsgCodec.composeFrom(_message);

        // We don't allow arbitrary src chain callers. If such a caller does send a message to this handler, the funds
        // will remain in this contract and will have to be rescued by an admin rescue function
        if (authorizedPeriphery != _composeFromBytes32) {
            revert UnauthorizedSrcPeriphery(_srcEid);
        }
    }
}
