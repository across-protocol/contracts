// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";
import "./PolygonTokenBridger.sol";

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
    using SafeERC20 for PolygonIERC20;

    // Address of FxChild which sends and receives messages to and from L1.
    address public fxChild;

    // Contract deployed on L1 and L2 processes all cross-chain transfers between this contract and the the HubPool.
    // Required because bridging tokens from Polygon to Ethereum has special constraints.
    PolygonTokenBridger public polygonTokenBridger;

    // Internal variable that only flips temporarily to true upon receiving messages from L1. Used to authenticate that
    // the caller is the fxChild AND that the fxChild called processMessageFromRoot
    bool private callValidated = false;

    event PolygonTokensBridged(address indexed token, address indexed receiver, uint256 amount);
    event SetFxChild(address indexed newFxChild);
    event SetPolygonTokenBridger(address indexed polygonTokenBridger);

    // Note: validating calls this way ensures that strange calls coming from the fxChild won't be misinterpreted.
    // Put differently, just checking that msg.sender == fxChild is not sufficient.
    // All calls that have admin priviledges must be fired from within the processMessageFromRoot method that's gone
    // through validation where the sender is checked and the root (mainnet) sender is also validated.
    // This modifier sets the callValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
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
     * @param _polygonTokenBridger Token routing contract that sends tokens from here to HubPool. Changeable by Admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wmaticAddress Replaces _wethAddress for this network since MATIC is the gas token and sent via msg.value
     * on Polygon.
     * @param _fxChild FxChild contract, changeable by Admin.
     * @param timerAddress Timer address to set.
     */
    constructor(
        PolygonTokenBridger _polygonTokenBridger,
        address _crossDomainAdmin,
        address _hubPool,
        address _wmaticAddress, // Note: wmatic is used here since it is the token sent via msg.value on polygon.
        address _fxChild,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wmaticAddress, timerAddress) {
        polygonTokenBridger = _polygonTokenBridger;
        fxChild = _fxChild;
    }

    /********************************************************
     *    ARBITRUM-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change FxChild address. Callable only by admin via processMessageFromRoot.
     * @param newFxChild New FxChild.
     */
    function setFxChild(address newFxChild) public onlyAdmin {
        fxChild = newFxChild;
        emit SetFxChild(fxChild);
    }

    /**
     * @notice Change polygonTokenBridger address. Callable only by admin via processMessageFromRoot.
     * @param newPolygonTokenBridger New Polygon Token Bridger contract.
     */
    function setPolygonTokenBridger(address payable newPolygonTokenBridger) public onlyAdmin {
        polygonTokenBridger = PolygonTokenBridger(newPolygonTokenBridger);
        emit SetPolygonTokenBridger(address(polygonTokenBridger));
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
    ) public validateInternalCalls nonReentrant {
        // Validation logic.
        require(msg.sender == fxChild, "Not from fxChild");
        require(rootMessageSender == crossDomainAdmin, "Not from mainnet admin");

        // This uses delegatecall to take the information in the message and process it as a function call on this contract.
        (bool success, ) = address(this).delegatecall(data);
        require(success, "delegatecall failed");
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        PolygonIERC20(relayerRefundLeaf.l2TokenAddress).safeIncreaseAllowance(
            address(polygonTokenBridger),
            relayerRefundLeaf.amountToReturn
        );

        // Note: WETH is WMATIC on matic, so this tells the tokenbridger that this is an unwrappable native token.
        polygonTokenBridger.send(
            PolygonIERC20(relayerRefundLeaf.l2TokenAddress),
            relayerRefundLeaf.amountToReturn,
            address(weth) == relayerRefundLeaf.l2TokenAddress
        );

        emit PolygonTokensBridged(relayerRefundLeaf.l2TokenAddress, address(this), relayerRefundLeaf.amountToReturn);
    }

    // @dev: This contract will trigger admin functions internally via the `processMessageFromRoot`, which is why
    // the `callValidated` check is made below  and why we use the `validateInternalCalls` modifier on
    // `processMessageFromRoot`. This prevents calling the admin functions from any other method besides
    // `processMessageFromRoot`.
    function _requireAdminSender() internal view override {
        require(callValidated, "Must call processMessageFromRoot");
    }
}
