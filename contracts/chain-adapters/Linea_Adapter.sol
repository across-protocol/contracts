// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import "../external/interfaces/WETH9Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMessageService {
    /**
     * @dev Emitted when a message is sent.
     * @dev We include the message hash to save hashing costs on the rollup.
     */
    event MessageSent(
        address indexed _from,
        address indexed _to,
        uint256 _fee,
        uint256 _value,
        uint256 _nonce,
        bytes _calldata,
        bytes32 indexed _messageHash
    );

    /**
     * @dev Emitted when a message is claimed.
     */
    event MessageClaimed(bytes32 indexed _messageHash);

    /**
     * @dev Thrown when fees are lower than the minimum fee.
     */
    error FeeTooLow();

    /**
     * @dev Thrown when fees are lower than value.
     */
    error ValueShouldBeGreaterThanFee();

    /**
     * @dev Thrown when the value sent is less than the fee.
     * @dev Value to forward on is msg.value - _fee.
     */
    error ValueSentTooLow();

    /**
     * @dev Thrown when the destination address reverts.
     */
    error MessageSendingFailed(address destination);

    /**
     * @dev Thrown when the destination address reverts.
     */
    error FeePaymentFailed(address recipient);

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
     * @notice Deliver a message to the destination chain.
     * @notice Is called automatically by the Postman, dApp or end user.
     * @param _from The msg.sender calling the origin message service.
     * @param _to The destination address on the destination chain.
     * @param _value The value to be transferred to the destination address.
     * @param _fee The message service fee on the origin chain.
     * @param _feeRecipient Address that will receive the fees.
     * @param _calldata The calldata used by the destination message service to call/forward to the destination contract.
     * @param _nonce Unique message number.
     */
    function claimMessage(
        address _from,
        address _to,
        uint256 _fee,
        uint256 _value,
        address payable _feeRecipient,
        bytes calldata _calldata,
        uint256 _nonce
    ) external;

    /**
     * @notice Returns the original sender of the message on the origin layer.
     * @return The original sender of the message on the origin layer.
     */
    function sender() external view returns (address);
}

interface ITokenBridge {
    event TokenReserved(address indexed token);
    event CustomContractSet(address indexed nativeToken, address indexed customContract, address indexed setBy);
    event BridgingInitiated(address indexed sender, address recipient, address indexed token, uint256 indexed amount);
    event BridgingFinalized(
        address indexed nativeToken,
        address indexed bridgedToken,
        uint256 indexed amount,
        address recipient
    );
    event NewToken(address indexed token);
    event NewTokenDeployed(address indexed bridgedToken, address indexed nativeToken);
    event RemoteTokenBridgeSet(address indexed remoteTokenBridge, address indexed setBy);
    event TokenDeployed(address indexed token);
    event DeploymentConfirmed(address[] tokens, address indexed confirmedBy);
    event MessageServiceUpdated(
        address indexed newMessageService,
        address indexed oldMessageService,
        address indexed setBy
    );

    error ReservedToken(address token);
    error RemoteTokenBridgeAlreadySet(address remoteTokenBridge);
    error AlreadyBridgedToken(address token);
    error InvalidPermitData(bytes4 permitData, bytes4 permitSelector);
    error PermitNotFromSender(address owner);
    error PermitNotAllowingBridge(address spender);
    error ZeroAmountNotAllowed(uint256 amount);
    error NotReserved(address token);
    error TokenNotDeployed(address token);
    error TokenNativeOnOtherLayer(address token);
    error AlreadyBrigedToNativeTokenSet(address token);
    error StatusAddressNotAllowed(address token);

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

    /**
     * @notice Similar to `bridgeToken` function but allows to pass additional
     *   permit data to do the ERC20 approval in a single transaction.
     * @param _token The address of the token to be bridged.
     * @param _amount The amount of the token to be bridged.
     * @param _recipient The address that will receive the tokens on the other chain.
     * @param _permitData The permit data for the token, if applicable.
     */
    function bridgeTokenWithPermit(
        address _token,
        uint256 _amount,
        address _recipient,
        bytes calldata _permitData
    ) external payable;

    /**
     * @dev It can only be called from the Message Service. To finalize the bridging
     *   process, a user or postmen needs to use the `claimMessage` function of the
     *   Message Service to trigger the transaction.
     * @param _nativeToken The address of the token on its native chain.
     * @param _amount The amount of the token to be received.
     * @param _recipient The address that will receive the tokens.
     * @param _chainId The source chainId or target chaindId for this token
     * @param _tokenMetadata Additional data used to deploy the bridged token if it
     *   doesn't exist already.
     */
    function completeBridging(
        address _nativeToken,
        uint256 _amount,
        address _recipient,
        uint256 _chainId,
        bytes calldata _tokenMetadata
    ) external;

    /**
     * @dev Change the address of the Message Service.
     * @param _messageService The address of the new Message Service.
     */
    function setMessageService(address _messageService) external;

    /**
     * @dev It can only be called from the Message Service. To change the status of
     *   the native tokens to DEPLOYED meaning they have been deployed on the other chain
     *   a user or postman needs to use the `claimMessage` function of the
     *   Message Service to trigger the transaction.
     * @param _nativeTokens The addresses of the native tokens.
     */
    function setDeployed(address[] memory _nativeTokens) external;

    /**
     * @dev Sets the address of the remote token bridge. Can only be called once.
     * @param _remoteTokenBridge The address of the remote token bridge to be set.
     */
    function setRemoteTokenBridge(address _remoteTokenBridge) external;

    /**
     * @dev Removes a token from the reserved list.
     * @param _token The address of the token to be removed from the reserved list.
     */
    function removeReserved(address _token) external;

    /**
     * @dev Linea can set a custom ERC20 contract for specific ERC20.
     *   For security purpose, Linea can only call this function if the token has
     *   not been bridged yet.
     * @param _nativeToken address of the token on the source chain.
     * @param _targetContract address of the custom contract.
     */
    function setCustomContract(address _nativeToken, address _targetContract) external;

    /**
     * @dev Pause the contract, can only be called by the owner.
     */
    function pause() external;

    /**
     * @dev Unpause the contract, can only be called by the owner.
     */
    function unpause() external;
}

interface IUSDCBridge {
    event MessageServiceUpdated(address indexed oldAddress, address indexed newAddress);
    event RemoteUSDCBridgeSet(address indexed newRemoteUSDCBridge);
    event Deposited(address indexed depositor, uint256 amount, address indexed to);
    event ReceivedFromOtherLayer(address indexed recipient, uint256 indexed amount);

    error NoBurnCapabilities(address addr);
    error AmountTooBig(uint256 amount, uint256 limit);
    error NotMessageService(address addr, address messageService);
    error ZeroAmountNotAllowed(uint256 amount);
    error NotFromRemoteUSDCBridge(address sender, address remoteUSDCBridge);
    error ZeroAddressNotAllowed(address addr);
    error RemoteUSDCBridgeNotSet();
    error SenderBalanceTooLow(uint256 amount, uint256 balance);
    error SameMessageServiceAddr(address messageService);
    error RemoteUSDCBridgeAlreadySet(address remoteUSDCBridge);

    /**
     * @dev Sends the sender's USDC from L1 to L2, locks the USDC sent
     * in this contract and sends a message to the message bridge
     * contract to mint the equivalent USDC on L2
     * @param amount The amount of USDC to send
     */
    function deposit(uint256 amount) external;

    /**
     * @dev Sends the sender's USDC from L1 to the recipient on L2, locks the USDC sent
     * in this contract and sends a message to the message bridge
     * contract to mint the equivalent USDC on L2
     * @param amount The amount of USDC to send
     * @param to The recipient's address to receive the funds
     */
    function depositTo(uint256 amount, address to) external payable;

    /**
     * @dev This function is called by the message bridge when transferring USDC from L2 to L1
     * It burns the USDC on L2 and unlocks the equivalent USDC from this contract to the recipient
     * @param recipient The recipient to receive the USDC on L1
     * @param amount The amount of USDC to receive
     */
    function receiveFromOtherLayer(address recipient, uint256 amount) external;
}

// solhint-disable-next-line contract-name-camelcase
contract Linea_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    WETH9Interface public immutable l1Weth;
    IERC20 public immutable l1Usdc;

    IMessageService public immutable l1MessageService;
    ITokenBridge public immutable l1TokenBridge;
    IUSDCBridge public immutable l1UsdcBridge;

    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _l1Usdc USDC address on L1.
     * @param _l1MessageService Canonical message service contract on L1.
     * @param _l1TokenBridge Canonical token bridge contract on L1.
     * @param _l1UsdcBridge L1 USDC Bridge to ConsenSys's L2 Linea.
     */
    constructor(
        WETH9Interface _l1Weth,
        IERC20 _l1Usdc,
        IMessageService _l1MessageService,
        ITokenBridge _l1TokenBridge,
        IUSDCBridge _l1UsdcBridge
    ) {
        l1Weth = _l1Weth;
        l1Usdc = _l1Usdc;
        l1MessageService = _l1MessageService;
        l1TokenBridge = _l1TokenBridge;
        l1UsdcBridge = _l1UsdcBridge;
    }

    /**
     * @notice Send cross-chain message to target on Linea.
     * @param target Contract on Linea that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        l1MessageService.sendMessage{ value: msg.value }(target, 0, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Bridge tokens to Linea.
     * @param l1Token L1 token to deposit.
     * @param l2Token L2 token to receive.
     * @param amount Amount of L1 tokens to deposit and L2 tokens to receive.
     * @param to Bridge recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        // If the l1Token is WETH then unwrap it to ETH then send the ETH directly
        // via the Canoncial Message Service.
        if (l1Token == address(l1Weth)) {
            l1Weth.withdraw(amount);
            l1MessageService.sendMessage{ value: amount }(to, 0, "");
        }
        // If the l1Token is USDC, then we need sent it via the USDC Bridge.
        else if (l1Token == address(l1Usdc)) {
            IERC20(l1Token).safeIncreaseAllowance(address(l1UsdcBridge), amount);
            l1UsdcBridge.depositTo(amount, to);
        }
        // For other tokens, we can use the Canonical Token Bridge.
        else {
            IERC20(l1Token).safeIncreaseAllowance(address(l1TokenBridge), amount);
            l1TokenBridge.bridgeToken(l1Token, amount, to);
        }

        emit TokensRelayed(l1Token, l2Token, amount, to);
    }
}
