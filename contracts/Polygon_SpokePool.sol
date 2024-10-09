// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./PolygonTokenBridger.sol";
import "./external/interfaces/WETH9Interface.sol";
import "./interfaces/SpokePoolInterface.sol";
import "./libraries/CircleCCTPAdapter.sol";

/**
 * @notice IFxMessageProcessor represents interface to process messages.
 */
interface IFxMessageProcessor {
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
        uint256 stateId,
        address rootMessageSender,
        bytes calldata data
    ) external;
}

/**
 * @notice Polygon specific SpokePool.
 * @custom:security-contact bugs@across.to
 */
contract Polygon_SpokePool is IFxMessageProcessor, SpokePool, CircleCCTPAdapter {
    using SafeERC20Upgradeable for PolygonIERC20Upgradeable;

    // Address of FxChild which sends and receives messages to and from L1.
    address public fxChild;

    // Contract deployed on L1 and L2 processes all cross-chain transfers between this contract and the HubPool.
    // Required because bridging tokens from Polygon to Ethereum has special constraints.
    PolygonTokenBridger public polygonTokenBridger;

    // Internal variable that only flips temporarily to true upon receiving messages from L1. Used to authenticate that
    // the caller is the fxChild AND that the fxChild called processMessageFromRoot
    bool private callValidated;

    error MulticallExecuteLeaf();

    event SetFxChild(address indexed newFxChild);
    event SetPolygonTokenBridger(address indexed polygonTokenBridger);
    event ReceivedMessageFromL1(address indexed caller, address indexed rootMessageSender);

    error CallValidatedAlreadySet();
    error CallValidatedNotSet();
    error DelegateCallFailed();
    error NotHubPool();
    error NotFxChild();

    // Note: validating calls this way ensures that strange calls coming from the fxChild won't be misinterpreted.
    // Put differently, just checking that msg.sender == fxChild is not sufficient.
    // All calls that have admin privileges must be fired from within the processMessageFromRoot method that's gone
    // through validation where the sender is checked and the root (mainnet) sender is also validated.
    // This modifier sets the callValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure callValidated is set to True only once at beginning of processMessageFromRoot, which prevents
        // processMessageFromRoot from being re-entered.
        if (callValidated) revert CallValidatedAlreadySet();

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed. See comment for `_requireAdminSender` for more details.
        callValidated = true;

        _;

        // Reset callValidated to false to disallow admin calls after this method exits.
        callValidated = false;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Polygon SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _polygonTokenBridger Token routing contract that sends tokens from here to HubPool. Changeable by Admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     * @param _fxChild FxChild contract, changeable by Admin.
     */
    function initialize(
        uint32 _initialDepositId,
        PolygonTokenBridger _polygonTokenBridger,
        address _crossDomainAdmin,
        address _withdrawalRecipient,
        address _fxChild
    ) public initializer {
        callValidated = false;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setPolygonTokenBridger(payable(_polygonTokenBridger));
        //slither-disable-next-line missing-zero-check
        _setFxChild(_fxChild);
    }

    /********************************************************
     *    POLYGON-SPECIFIC CROSS-CHAIN ADMIN FUNCTIONS     *
     ********************************************************/

    /**
     * @notice Change FxChild address. Callable only by admin via processMessageFromRoot.
     * @param newFxChild New FxChild.
     */
    function setFxChild(address newFxChild) public onlyAdmin nonReentrant {
        _setFxChild(newFxChild);
    }

    /**
     * @notice Change polygonTokenBridger address. Callable only by admin via processMessageFromRoot.
     * @param newPolygonTokenBridger New Polygon Token Bridger contract.
     */
    function setPolygonTokenBridger(address payable newPolygonTokenBridger) public onlyAdmin nonReentrant {
        _setPolygonTokenBridger(newPolygonTokenBridger);
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
        if (msg.sender != fxChild) revert NotFxChild();
        if (rootMessageSender != crossDomainAdmin) revert NotHubPool();

        // This uses delegatecall to take the information in the message and process it as a function call on this contract.
        /// This is a safe delegatecall because its made to address(this) so there is no risk of delegating to a
        /// selfdestruct().
        //slither-disable-start low-level-calls
        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(data);
        //slither-disable-end low-level-calls
        if (!success) revert DelegateCallFailed();

        emit ReceivedMessageFromL1(msg.sender, rootMessageSender);
    }

    /**
     * @notice Allows the caller to trigger the wrapping of any unwrapped matic tokens.
     * @dev Unlike other ERC20 transfers, Matic transfers from L1 -> L2 bridging don't result in an L2 call into
     * the contract receiving the tokens, so wrapping must be done via a separate transaction. In other words,
     * we can't rely upon a `fallback()` method being triggered to wrap MATIC upon receiving it.
     */
    function wrap() public nonReentrant {
        _wrap();
    }

    /**
     * @notice Override multicall so that it cannot include executeRelayerRefundLeaf
     * as one of the calls combined with other public function calls.
     * @dev Multicalling a single transaction will always succeed.
     * @dev Multicalling execute functions without combining other public function calls will succeed.
     * @dev Multicalling public function calls without combining execute functions will succeed.
     */
    function _validateMulticallData(bytes[] calldata data) internal pure override {
        bool hasOtherPublicFunctionCall = false;
        bool hasExecutedLeafCall = false;
        for (uint256 i = 0; i < data.length; i++) {
            bytes4 selector = bytes4(data[i][:4]);
            if (selector == SpokePoolInterface.executeRelayerRefundLeaf.selector) {
                if (hasOtherPublicFunctionCall) revert MulticallExecuteLeaf();
                hasExecutedLeafCall = true;
            } else {
                if (hasExecutedLeafCall) revert MulticallExecuteLeaf();
                hasOtherPublicFunctionCall = true;
            }
        }
    }

    /**
     * @notice This function can send an L2 to L1 message so we are extra cautious about preventing a griefing vector
     * whereby someone batches this call with a bunch of other calls and produces a very large L2 burn transaction.
     * This might make the L2 -> L1 message fail due to exceeding the L1 calldata limit.
     */

    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public payable override {
        // AddressLibUpgradeable.isContract isn't a sufficient check because it checks the contract code size of
        // msg.sender which is 0 if called from a constructor function on msg.sender. This is why we check if
        // msg.sender is equal to tx.origin which is fine as long as Polygon supports the tx.origin opcode.
        // solhint-disable-next-line avoid-tx-origin
        if (relayerRefundLeaf.amountToReturn > 0 && msg.sender != tx.origin) revert NotEOA();
        super.executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _setFxChild(address _fxChild) internal {
        //slither-disable-next-line missing-zero-check
        fxChild = _fxChild;
        emit SetFxChild(_fxChild);
    }

    function _setPolygonTokenBridger(address payable _polygonTokenBridger) internal {
        polygonTokenBridger = PolygonTokenBridger(_polygonTokenBridger);
        emit SetPolygonTokenBridger(address(_polygonTokenBridger));
    }

    function _preExecuteLeafHook(address) internal override {
        // Wraps MATIC --> WMATIC before distributing tokens from this contract.
        _wrap();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // If the token is USDC, we need to use the CCTP bridge to transfer it to the hub pool.
        if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(withdrawalRecipient, amountToReturn);
        } else {
            PolygonIERC20Upgradeable(l2TokenAddress).safeIncreaseAllowance(
                address(polygonTokenBridger),
                amountToReturn
            );
            // Note: WrappedNativeToken is WMATIC on matic, so this tells the tokenbridger that this is an unwrappable native token.
            polygonTokenBridger.send(PolygonIERC20Upgradeable(l2TokenAddress), amountToReturn);
        }
    }

    function _wrap() internal {
        uint256 balance = address(this).balance;
        //slither-disable-next-line arbitrary-send-eth
        if (balance > 0) wrappedNativeToken.deposit{ value: balance }();
    }

    // @dev: This contract will trigger admin functions internally via the `processMessageFromRoot`, which is why
    // the `callValidated` check is made below  and why we use the `validateInternalCalls` modifier on
    // `processMessageFromRoot`. This prevents calling the admin functions from any other method besides
    // `processMessageFromRoot`.
    function _requireAdminSender() internal view override {
        if (!callValidated) revert CallValidatedNotSet();
    }
}
