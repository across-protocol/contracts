// SPDX-License-Identifier: BUSL-1.1

// Linea only support v0.8.19
// See https://docs.linea.build/build-on-linea/ethereum-differences#evm-opcodes
pragma solidity 0.8.19;

import "./SpokePool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Interface of Linea's Canonical Message Service
 * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/interfaces/IMessageService.sol
 */
interface IMessageService {
    /**
     * @notice Sends a message for transporting from the given chain.
     * @dev This function should be called with a msg.value = _value + _fee. The fee will be paid on the destination chain.
     * @param _to The destination address on the destination chain.
     * @param _fee The message service fee on the origin chain.
     * @param _calldata The calldata used by the destination message service to call the destination contract.
     */
    function sendMessage(
        address _to,
        uint256 _fee,
        bytes calldata _calldata
    ) external payable;

    /**
     * @notice Returns the original sender of the message on the origin layer.
     */
    function sender() external view returns (address);

    /**
     * @notice Minimum fee to use when sending a message. Currently, only exists on L2MessageService.
     * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/messageService/l2/L2MessageService.sol#L37
     */
    function minimumFeeInWei() external view returns (uint256);
}

/**
 * @notice Interface of Linea's Canonical Token Bridge
 * See https://github.com/Consensys/linea-contracts/blob/3cf85529fd4539eb06ba998030c37e47f98c528a/contracts/tokenBridge/interfaces/ITokenBridge.sol
 */
interface ITokenBridge {
    /**
     * @notice This function is the single entry point to bridge tokens to the
     *   other chain, both for native and already bridged tokens. You can use it
     *   to bridge any ERC20. If the token is bridged for the first time an ERC20
     *   (BridgedToken.sol) will be automatically deployed on the target chain.
     * @dev User should first allow the bridge to transfer tokens on his behalf.
     *   Alternatively, you can use `bridgeTokenWithPermit` to do so in a single
     *   transaction. If you want the transfer to be automatically executed on the
     *   destination chain. You should send enough ETH to pay the postman fees.
     *   Note that Linea can reserve some tokens (which use a dedicated bridge).
     *   In this case, the token cannot be bridged. Linea can only reserve tokens
     *   that have not been bridged yet.
     *   Linea can pause the bridge for security reason. In this case new bridge
     *   transaction would revert.
     * @param _token The address of the token to be bridged.
     * @param _amount The amount of the token to be bridged.
     * @param _recipient The address that will receive the tokens on the other chain.
     */
    function bridgeToken(
        address _token,
        uint256 _amount,
        address _recipient
    ) external payable;
}

interface IUSDCBridge {
    function usdc() external view returns (address);

    /**
     * @dev Sends the sender's USDC from L1 to the recipient on L2, locks the USDC sent
     * in this contract and sends a message to the message bridge
     * contract to mint the equivalent USDC on L2
     * @param amount The amount of USDC to send
     * @param to The recipient's address to receive the funds
     */
    function depositTo(uint256 amount, address to) external payable;
}

/**
 * @notice Linea specific SpokePool.
 */
contract Linea_SpokePool is SpokePool {
    using SafeERC20 for IERC20;

    IMessageService public l2MessageService;
    ITokenBridge public l2TokenBridge;
    IUSDCBridge public l2UsdcBridge;

    event LineaTokensBridged(address indexed l2Token, address target, uint256 numberOfTokensBridged);
    event SetL2TokenBridge(address indexed newTokenBridge, address oldTokenBridge);
    event SetL2MessageService(address indexed newMessageService, address oldMessageService);
    event SetL2UsdcBridge(address indexed newUsdcBridge, address oldUsdcBridge);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Linea SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _l2MessageService Address of Canonical Message Service. Can be reset by admin.
     * @param _l2TokenBridge Address of Canonical Token Bridge. Can be reset by admin.
     * @param _l2UsdcBridge Address of USDC Bridge. Can be reset by admin.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        uint32 _initialDepositId,
        IMessageService _l2MessageService,
        ITokenBridge _l2TokenBridge,
        IUSDCBridge _l2UsdcBridge,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        _setL2TokenBridge(_l2TokenBridge);
        _setL2MessageService(_l2MessageService);
        _setL2UsdcBridge(_l2UsdcBridge);
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

    /**
     * @notice Change L2 USDC bridge address. Callable only by admin.
     * @param _l2UsdcBridge New address of L2 USDC bridge.
     */
    function setL2UsdcBridge(IUSDCBridge _l2UsdcBridge) public onlyAdmin nonReentrant {
        _setL2UsdcBridge(_l2UsdcBridge);
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
        uint256 minFee = IMessageService(l2MessageService).minimumFeeInWei();
        require(msg.value == minFee, "MESSAGE_FEE_MISMATCH");

        // SpokePool is expected to receive ETH from the L1 HubPool, then we need to first unwrap it to ETH and then
        // send ETH directly via the Canonical Message Service.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn); // Unwrap into ETH.
            IMessageService(l2MessageService).sendMessage{ value: amountToReturn + msg.value }(hubPool, msg.value, "");
        }
        // If the l1Token is USDC, then we need sent it via the USDC Bridge.
        else if (l2TokenAddress == l2UsdcBridge.usdc()) {
            IERC20(l2TokenAddress).safeIncreaseAllowance(address(l2UsdcBridge), amountToReturn);
            l2UsdcBridge.depositTo{ value: msg.value }(amountToReturn, hubPool);
        }
        // For other tokens, we can use the Canonical Token Bridge.
        else {
            IERC20(l2TokenAddress).safeIncreaseAllowance(address(l2TokenBridge), amountToReturn);
            l2TokenBridge.bridgeToken{ value: msg.value }(l2TokenAddress, amountToReturn, hubPool);
        }

        emit LineaTokensBridged(l2TokenAddress, hubPool, amountToReturn);
    }

    function _requireAdminSender() internal view override {
        require(IMessageService(l2MessageService).sender() == crossDomainAdmin, "ONLY_COUNTERPART_GATEWAY");
    }

    function _setL2TokenBridge(ITokenBridge _l2TokenBridge) internal {
        address oldTokenBridge = address(l2TokenBridge);
        l2TokenBridge = _l2TokenBridge;
        emit SetL2TokenBridge(address(_l2TokenBridge), oldTokenBridge);
    }

    function _setL2UsdcBridge(IUSDCBridge _l2UsdcBridge) internal {
        address oldUsdcBridge = address(l2UsdcBridge);
        l2UsdcBridge = _l2UsdcBridge;
        emit SetL2UsdcBridge(address(_l2UsdcBridge), oldUsdcBridge);
    }

    function _setL2MessageService(IMessageService _l2MessageService) internal {
        address oldMessageService = address(l2MessageService);
        l2MessageService = _l2MessageService;
        emit SetL2MessageService(address(_l2MessageService), oldMessageService);
    }
}
