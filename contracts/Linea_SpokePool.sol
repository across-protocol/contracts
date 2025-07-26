// SPDX-License-Identifier: BUSL-1.1

// Linea only support v0.8.19
// See https://docs.linea.build/build-on-linea/ethereum-differences#evm-opcodes
pragma solidity ^0.8.19;

import "./SpokePool.sol";
import "./libraries/CircleCCTPAdapter.sol";
import { IMessageService, ITokenBridge, IUSDCBridge } from "./external/interfaces/LineaInterfaces.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Linea specific SpokePool.
 * @custom:security-contact bugs@across.to
 */
contract Linea_SpokePool is SpokePool, CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Address of Linea's Canonical Message Service contract on L2.
     */
    IMessageService public l2MessageService;

    /**
     * @notice Address of Linea's Canonical Token Bridge contract on L2.
     */
    ITokenBridge public l2TokenBridge;

    /**
     * @notice Address of Linea's USDC Bridge contract on L2.
     */
    IUSDCBridge private DEPRECATED_l2UsdcBridge;

    /**************************************
     *               EVENTS               *
     **************************************/
    event SetL2TokenBridge(address indexed newTokenBridge, address oldTokenBridge);
    event SetL2MessageService(address indexed newMessageService, address oldMessageService);

    /**
     * @notice Construct Linea-specific SpokePool.
     * @param _wrappedNativeTokenAddress Address of WETH on Linea.
     * @param _depositQuoteTimeBuffer Quote timestamps can't be set more than this amount
     * into the past from the block time of the deposit.
     * @param _fillDeadlineBuffer Fill deadlines can't be set more than this amount
     * into the future from the block time of the deposit.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            // Linea_SpokePool does not use OFT messaging; setting destination eid and fee cap to 0
            0,
            0
        )
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Initialize Linea-specific SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _l2MessageService Address of Canonical Message Service. Can be reset by admin.
     * @param _l2TokenBridge Address of Canonical Token Bridge. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        uint32 _initialDepositId,
        IMessageService _l2MessageService,
        ITokenBridge _l2TokenBridge,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient);
        _setL2TokenBridge(_l2TokenBridge);
        _setL2MessageService(_l2MessageService);
    }

    /**
     * @notice Returns current min. fee set by Linea's Canonical Message Service for
     * sending L2->L1 messages.
     */
    function minimumFeeInWei() public view returns (uint256) {
        return l2MessageService.minimumFeeInWei();
    }

    /****************************************
     *    LINEA-SPECIFIC ADMIN FUNCTIONS    *
     ****************************************/

    /**
     * @notice Change L2 token bridge address. Callable only by admin.
     * @param _l2TokenBridge New address of L2 token bridge.
     */
    function setL2TokenBridge(ITokenBridge _l2TokenBridge) public onlyAdmin nonReentrant {
        _setL2TokenBridge(_l2TokenBridge);
    }

    /**
     * @notice Change L2 message service address. Callable only by admin.
     * @param _l2MessageService New address of L2 message service.
     */
    function setL2MessageService(IMessageService _l2MessageService) public onlyAdmin nonReentrant {
        _setL2MessageService(_l2MessageService);
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
    // if ETH on Linea is treated as ETH and the fallback() function is triggered when this contract receives
    // ETH. We will have to test this but this function for now allows the contract to safely convert all of its
    // held ETH into WETH at the cost of higher gas costs.
    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // Linea's L2 Canonical Message Service, requires a minimum fee to be set.
        uint256 minFee = minimumFeeInWei();

        // SpokePool is expected to receive ETH from the L1 HubPool, then we need to first unwrap it to ETH and then
        // send ETH directly via the Canonical Message Service.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            // We require that the caller pass in the fees as msg.value instead of pulling ETH out of this contract's balance.
            // Using the contract's balance would require a separate accounting system to keep LP funds separated from system funds
            // used to pay for L2->L1 messages.
            require(msg.value == minFee, "MESSAGE_FEE_MISMATCH");

            // msg.value is added here because the entire native balance (including msg.value) is auto-wrapped
            // before the execution of any wrapped token refund leaf. So it must be unwrapped before being sent as a
            // fee to the l2MessageService.
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn + msg.value); // Unwrap into ETH.
            l2MessageService.sendMessage{ value: amountToReturn + msg.value }(withdrawalRecipient, msg.value, "");
        }
        // If the l2Token is USDC, then we need sent it via the USDC Bridge.
        else if (l2TokenAddress == address(usdcToken) && _isCCTPEnabled()) {
            _transferUsdc(withdrawalRecipient, amountToReturn);
        }
        // For other tokens, we can use the Canonical Token Bridge.
        else {
            // We require that the caller pass in the fees as msg.value instead of pulling ETH out of this contract's balance.
            // Using the contract's balance would require a separate accounting system to keep LP funds separated from system funds
            // used to pay for L2->L1 messages.
            require(msg.value == minFee, "MESSAGE_FEE_MISMATCH");

            IERC20(l2TokenAddress).safeIncreaseAllowance(address(l2TokenBridge), amountToReturn);
            l2TokenBridge.bridgeToken{ value: msg.value }(l2TokenAddress, amountToReturn, withdrawalRecipient);
        }
    }

    function _requireAdminSender() internal view override {
        require(
            l2MessageService.sender() == crossDomainAdmin && msg.sender == address(l2MessageService),
            "ONLY_COUNTERPART_GATEWAY"
        );
    }

    function _setL2TokenBridge(ITokenBridge _l2TokenBridge) internal {
        address oldTokenBridge = address(l2TokenBridge);
        l2TokenBridge = _l2TokenBridge;
        emit SetL2TokenBridge(address(_l2TokenBridge), oldTokenBridge);
    }

    function _setL2MessageService(IMessageService _l2MessageService) internal {
        address oldMessageService = address(l2MessageService);
        l2MessageService = _l2MessageService;
        emit SetL2MessageService(address(_l2MessageService), oldMessageService);
    }
}
