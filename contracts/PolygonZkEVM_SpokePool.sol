// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./external/interfaces/IPolygonZkEVMBridge.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Define interface for PolygonZkEVM Bridge message receiver
 * See https://github.com/0xPolygonHermez/zkevm-contracts/blob/53e95f3a236d8bea87c27cb8714a5d21496a3b20/contracts/interfaces/IBridgeMessageReceiver.sol
 */
interface IBridgeMessageReceiver {
    /**
     * @notice This will be called by the Polygon zkEVM Bridge on L2 to relay a message sent from the HubPool.
     * @param originAddress Address of the original message sender on L1.
     * @param originNetwork Polygon zkEVM's internal network id of source chain.
     * @param data Data to be received and executed on this contract.
     */
    function onMessageReceived(
        address originAddress,
        uint32 originNetwork,
        bytes memory data
    ) external payable;
}

/**
 * @notice Polygon zkEVM Spoke pool.
 * @custom:security-contact bugs@across.to
 */
contract PolygonZkEVM_SpokePool is SpokePool, IBridgeMessageReceiver {
    using SafeERC20 for IERC20;

    // Address of Polygon zkEVM's Canonical Bridge on L2.
    IPolygonZkEVMBridge public l2PolygonZkEVMBridge;

    // Polygon zkEVM's internal network id for L1.
    uint32 public constant POLYGON_ZKEVM_L1_NETWORK_ID = 0;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private adminCallValidated;

    /**************************************
     *               ERRORS               *
     **************************************/
    error AdminCallValidatedAlreadySet();
    error CallerNotBridge();
    error OriginSenderNotCrossDomain();
    error SourceChainNotHubChain();
    error AdminCallNotValidated();

    /**************************************
     *               EVENTS               *
     **************************************/
    event SetPolygonZkEVMBridge(address indexed newPolygonZkEVMBridge, address indexed oldPolygonZkEVMBridge);
    event ReceivedMessageFromL1(address indexed caller, address indexed originAddress);

    // Note: validating calls this way ensures that strange calls coming from the onMessageReceived won't be
    // misinterpreted. Put differently, just checking that originAddress == crossDomainAdmint is not sufficient.
    // All calls that have admin privileges must be fired from within the onMessageReceived method that's gone
    // through validation where the sender is checked and the sender from the other chain is also validated.
    // This modifier sets the adminCallValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure adminCallValidated is set to True only once at beginning of onMessageReceived, which prevents
        // onMessageReceived from being re-entered.
        if (adminCallValidated) {
            revert AdminCallValidatedAlreadySet();
        }

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed.
        adminCallValidated = true;

        _;

        // Reset adminCallValidated to false to disallow admin calls after this method exits.
        adminCallValidated = false;
    }

    /**
     * @notice Construct Polygon zkEVM specific SpokePool.
     * @param _wrappedNativeTokenAddress Address of WETH on Polygon zkEVM.
     * @param _depositQuoteTimeBuffer Quote timestamps can't be set more than this amount
     * into the past from the block time of the deposit.
     * @param _fillDeadlineBuffer Fill deadlines can't be set more than this amount
     * into the future from the block time of the deposit.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Polygon zkEVM SpokePool.
     * @param _l2PolygonZkEVMBridge Address of Polygon zkEVM's canonical bridge contract on L2.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        IPolygonZkEVMBridge _l2PolygonZkEVMBridge,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setL2PolygonZkEVMBridge(_l2PolygonZkEVMBridge);
    }

    /**
     * @notice Admin can reset the Polygon zkEVM bridge contract address.
     * @param _l2PolygonZkEVMBridge Address of the new canonical bridge.
     */
    function setL2PolygonZkEVMBridge(IPolygonZkEVMBridge _l2PolygonZkEVMBridge) external onlyAdmin {
        _setL2PolygonZkEVMBridge(_l2PolygonZkEVMBridge);
    }

    /**
     * @notice This will be called by the Polygon zkEVM Bridge on L2 to relay a message sent from the HubPool.
     * @param _originAddress Address of the original message sender on L1.
     * @param _originNetwork Polygon zkEVM's internal network id of source chain.
     * @param _data Data to be received and executed on this contract.
     */
    function onMessageReceived(
        address _originAddress,
        uint32 _originNetwork,
        bytes memory _data
    ) external payable override validateInternalCalls {
        if (msg.sender != address(l2PolygonZkEVMBridge)) {
            revert CallerNotBridge();
        }
        if (_originAddress != crossDomainAdmin) {
            revert OriginSenderNotCrossDomain();
        }
        if (_originNetwork != POLYGON_ZKEVM_L1_NETWORK_ID) {
            revert SourceChainNotHubChain();
        }

        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_data);
        require(success, "delegatecall failed");

        emit ReceivedMessageFromL1(msg.sender, _originAddress);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    /**
     * @notice Wraps any ETH into WETH before executing base function. This is necessary because SpokePool receives
     * ETH over the canonical token bridge instead of WETH.
     */
    function _preExecuteLeafHook(address l2TokenAddress) internal override {
        if (l2TokenAddress == address(wrappedNativeToken)) _depositEthToWeth();
    }

    // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is necessary because
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. This may not be neccessary
    // if ETH on Polygon zkEVM is treated as ETH and the fallback() function is triggered when this contract receives
    // ETH. We will have to test this but this function for now allows the contract to safely convert all of its
    // held ETH into WETH at the cost of higher gas costs.
    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // SpokePool is expected to receive ETH from the L1 HubPool, then we need to first unwrap it to ETH and then
        // send ETH directly via the native L2 bridge.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn); // Unwrap into ETH.
            l2PolygonZkEVMBridge.bridgeAsset{ value: amountToReturn }(
                POLYGON_ZKEVM_L1_NETWORK_ID,
                withdrawalRecipient,
                amountToReturn,
                address(0),
                true, // Indicates if the new global exit root is updated or not, which is true for asset bridges
                ""
            );
        } else {
            IERC20(l2TokenAddress).safeIncreaseAllowance(address(l2PolygonZkEVMBridge), amountToReturn);
            l2PolygonZkEVMBridge.bridgeAsset(
                POLYGON_ZKEVM_L1_NETWORK_ID,
                withdrawalRecipient,
                amountToReturn,
                l2TokenAddress,
                true, // Indicates if the new global exit root is updated or not, which is true for asset bridges
                ""
            );
        }
    }

    // Check that the onMessageReceived method has validated the method to ensure the sender is authenticated.
    function _requireAdminSender() internal view override {
        if (!adminCallValidated) {
            revert AdminCallNotValidated();
        }
    }

    function _setL2PolygonZkEVMBridge(IPolygonZkEVMBridge _newL2PolygonZkEVMBridge) internal {
        address oldL2PolygonZkEVMBridge = address(l2PolygonZkEVMBridge);
        l2PolygonZkEVMBridge = _newL2PolygonZkEVMBridge;
        emit SetPolygonZkEVMBridge(address(_newL2PolygonZkEVMBridge), oldL2PolygonZkEVMBridge);
    }
}
