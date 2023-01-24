// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./PolygonTokenBridger.sol";
import "./interfaces/WETH9.sol";
import "./SpokePoolInterface.sol";

// IFxMessageProcessor represents interface to process messages.
interface IFxMessageProcessor {
    function processMessageFromRoot(
        uint256 stateId,
        address rootMessageSender,
        bytes calldata data
    ) external;
}

/**
 * @notice Polygon specific SpokePool.
 */
contract Polygon_SpokePool is IFxMessageProcessor, SpokePool {
    using SafeERC20Upgradeable for PolygonIERC20Upgradeable;

    // Address of FxChild which sends and receives messages to and from L1.
    address public fxChild;

    // Contract deployed on L1 and L2 processes all cross-chain transfers between this contract and the the HubPool.
    // Required because bridging tokens from Polygon to Ethereum has special constraints.
    PolygonTokenBridger public polygonTokenBridger;

    // Internal variable that only flips temporarily to true upon receiving messages from L1. Used to authenticate that
    // the caller is the fxChild AND that the fxChild called processMessageFromRoot
    bool private callValidated;

    event PolygonTokensBridged(address indexed token, address indexed receiver, uint256 amount);
    event SetFxChild(address indexed newFxChild);
    event SetPolygonTokenBridger(address indexed polygonTokenBridger);

    // Note: validating calls this way ensures that strange calls coming from the fxChild won't be misinterpreted.
    // Put differently, just checking that msg.sender == fxChild is not sufficient.
    // All calls that have admin privileges must be fired from within the processMessageFromRoot method that's gone
    // through validation where the sender is checked and the root (mainnet) sender is also validated.
    // This modifier sets the callValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure callValidated is set to True only once at beginning of processMessageFromRoot, which prevents
        // processMessageFromRoot from being re-entered.
        require(!callValidated, "callValidated already set");

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed. See
        callValidated = true;

        _;

        // Reset callValidated to false to disallow admin calls after this method exits.
        callValidated = false;
    }

    /**
     * @notice Construct the Polygon SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _polygonTokenBridger Token routing contract that sends tokens from here to HubPool. Changeable by Admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wmaticAddress Replaces wrappedNativeToken for this network since MATIC is the native currency on polygon.
     * @param _fxChild FxChild contract, changeable by Admin.
     * @param _timerAddress Timer address to set.
     */
    function initialize(
        uint32 _initialDepositId,
        PolygonTokenBridger _polygonTokenBridger,
        address _crossDomainAdmin,
        address _hubPool,
        address _wmaticAddress, // Note: wmatic is used here since it is the token sent via msg.value on polygon.
        address _fxChild,
        address _timerAddress
    ) public initializer {
        callValidated = false;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wmaticAddress, _timerAddress);
        polygonTokenBridger = _polygonTokenBridger;
        fxChild = _fxChild;
    }

    /********************************************************
     *    POLYGON-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change FxChild address. Callable only by admin via processMessageFromRoot.
     * @param newFxChild New FxChild.
     */
    function setFxChild(address newFxChild) public onlyAdmin nonReentrant {
        fxChild = newFxChild;
        emit SetFxChild(newFxChild);
    }

    /**
     * @notice Change polygonTokenBridger address. Callable only by admin via processMessageFromRoot.
     * @param newPolygonTokenBridger New Polygon Token Bridger contract.
     */
    function setPolygonTokenBridger(address payable newPolygonTokenBridger) public onlyAdmin nonReentrant {
        polygonTokenBridger = PolygonTokenBridger(newPolygonTokenBridger);
        emit SetPolygonTokenBridger(address(newPolygonTokenBridger));
    }

    /**
     * @notice Called by FxChild upon receiving L1 message that targets this contract. Performs an additional check
     * that the L1 caller was the expected cross domain admin, and then delegate calls.
     * @notice Polygon bridge only executes this external function on the target Polygon contract when relaying
     * messages from L1, so all functions on this SpokePool are expected to originate via this call.
     * @dev stateId value isn't used because it isn't relevant for this method. It doesn't care what state sync
     * triggered this call.
     * @param rootMessageSender Original L1 sender of data.
     * @param data ABI encoded function call to execute on this contract.
     */
    function processMessageFromRoot(
        uint256, /*stateId*/
        address rootMessageSender,
        bytes calldata data
    ) public validateInternalCalls {
        // Validation logic.
        require(msg.sender == fxChild, "Not from fxChild");
        require(rootMessageSender == crossDomainAdmin, "Not from mainnet admin");

        // This uses delegatecall to take the information in the message and process it as a function call on this contract.
        /// This is a safe delegatecall because its made to address(this) so there is no risk of delegating to a
        /// selfdestruct().
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(data);
        require(success, "delegatecall failed");
    }

    /**
     * @notice Allows the caller to trigger the wrapping of any unwrapped matic tokens.
     * @dev Matic sends via L1 -> L2 bridging actions don't call into the contract receiving the tokens, so wrapping
     * must be done via a separate transaction.
     */
    function wrap() public nonReentrant {
        _wrap();
    }

    /**
     * @notice Executes a relayer refund leaf stored as part of a root bundle. Will send the relayer the amount they
     * sent to the recipient plus a relayer fee.
     * @dev this is only overridden to wrap any matic the contract holds before running.
     * @param rootBundleId Unique ID of root bundle containing relayer refund root that this leaf is contained in.
     * @param relayerRefundLeaf Contains all data necessary to reconstruct leaf contained in root bundle and to
     * refund relayer. This data structure is explained in detail in the SpokePoolInterface.
     * @param proof Inclusion proof for this leaf in relayer refund root in root bundle.
     */
    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public override nonReentrant {
        _wrap();
        _executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    /**
     * @notice Executes a slow relay leaf stored as part of a root bundle. Will send the full amount remaining in the
     * relay to the recipient, less fees.
     * @dev This function assumes that the relay's destination chain ID is the current chain ID, which prevents
     * the caller from executing a slow relay intended for another chain on this chain. This is only overridden to call
     * wrap before running the function.
     * @param depositor Depositor on origin chain who set this chain as the destination chain.
     * @param recipient Specified recipient on this chain.
     * @param destinationToken Token to send to recipient. Should be mapped to the origin token, origin chain ID
     * and this chain ID via a mapping on the HubPool.
     * @param amount Full size of the deposit.
     * @param originChainId Chain of SpokePool where deposit originated.
     * @param realizedLpFeePct Fee % based on L1 HubPool utilization at deposit quote time. Deterministic based on
     * quote time.
     * @param relayerFeePct Original fee % to keep as relayer set by depositor.
     * @param depositId Unique deposit ID on origin spoke pool.
     * @param rootBundleId Unique ID of root bundle containing slow relay root that this leaf is contained in.
     * @param proof Inclusion proof for this leaf in slow relay root in root bundle.
     */
    function executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) public virtual override nonReentrant {
        _wrap();
        _executeSlowRelayLeaf(
            depositor,
            recipient,
            destinationToken,
            amount,
            originChainId,
            chainId(),
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            proof
        );
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        PolygonIERC20Upgradeable(relayerRefundLeaf.l2TokenAddress).safeIncreaseAllowance(
            address(polygonTokenBridger),
            relayerRefundLeaf.amountToReturn
        );

        // Note: WrappedNativeToken is WMATIC on matic, so this tells the tokenbridger that this is an unwrappable native token.
        polygonTokenBridger.send(
            PolygonIERC20Upgradeable(relayerRefundLeaf.l2TokenAddress),
            relayerRefundLeaf.amountToReturn
        );

        emit PolygonTokensBridged(relayerRefundLeaf.l2TokenAddress, address(this), relayerRefundLeaf.amountToReturn);
    }

    function _wrap() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) wrappedNativeToken.deposit{ value: balance }();
    }

    // @dev: This contract will trigger admin functions internally via the `processMessageFromRoot`, which is why
    // the `callValidated` check is made below  and why we use the `validateInternalCalls` modifier on
    // `processMessageFromRoot`. This prevents calling the admin functions from any other method besides
    // `processMessageFromRoot`.
    function _requireAdminSender() internal view override {
        require(callValidated, "Must call processMessageFromRoot");
    }
}
