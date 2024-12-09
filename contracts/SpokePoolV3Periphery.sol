// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";
import { Lockable } from "./Lockable.sol";
import { V3SpokePoolInterface } from "./interfaces/V3SpokePoolInterface.sol";
import { IERC20Auth } from "./external/interfaces/IERC20Auth.sol";
import { WETH9Interface } from "./external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "./external/interfaces/IPermit2.sol";
import { PeripherySigningLib } from "./libraries/PeripherySigningLib.sol";
import { SpokePoolV3PeripheryProxyInterface, SpokePoolV3PeripheryInterface } from "./interfaces/SpokePoolV3PeripheryInterface.sol";

/**
 * @title SpokePoolPeripheryProxy
 * @notice User should only call SpokePoolV3Periphery contract functions that require approvals through this
 * contract. This is purposefully a simple passthrough contract so that the user only approves this contract to
 * pull its assets because the SpokePoolV3Periphery contract can be used to call
 * any calldata on any exchange that the user wants to. By separating the contract that is approved to spend
 * user funds from the contract that executes arbitrary calldata, the SpokePoolPeriphery does not
 * need to validate the calldata that gets executed.
 * @dev If this proxy didn't exist and users instead approved and interacted directly with the SpokePoolV3Periphery
 * then users would run the unneccessary risk that another user could instruct the Periphery contract to steal
 * any approved tokens that the user had left outstanding.
 */
contract SpokePoolPeripheryProxy is SpokePoolV3PeripheryProxyInterface, Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // Flag set for one time initialization.
    bool private initialized;

    // The SpokePoolPeriphery should be deterministically deployed at the same address across all networks,
    // so this contract should also be able to be deterministically deployed at the same address across all networks
    // since the periphery address is the only constructor argument.
    SpokePoolV3Periphery public SPOKE_POOL_PERIPHERY;

    error InvalidPeriphery();
    error ContractInitialized();

    /**
     * @notice Construct a new Proxy contract.
     * @dev Is empty and all of the state variables are initialized in the initialize function
     * to allow for deployment at a deterministic address via create2, which requires that the bytecode
     * across different networks is the same. Constructor parameters affect the bytecode so we can only
     * add parameters here that are consistent across networks.
     */
    constructor() {}

    /**
     * @notice Initialize the SpokePoolPeripheryProxy contract.
     * @param _spokePoolPeriphery Address of the SpokePoolPeriphery contract that this proxy will call.
     */
    function initialize(SpokePoolV3Periphery _spokePoolPeriphery) external nonReentrant {
        if (initialized) revert ContractInitialized();
        initialized = true;
        if (!address(_spokePoolPeriphery).isContract()) revert InvalidPeriphery();
        SPOKE_POOL_PERIPHERY = _spokePoolPeriphery;
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     */
    function swapAndBridge(SpokePoolV3PeripheryInterface.SwapAndDepositData calldata swapAndDepositData)
        external
        override
        nonReentrant
    {
        _callSwapAndBridge(swapAndDepositData);
    }

    /**
     * @notice Calls swapAndBridge on the spoke pool periphery contract.
     * @param swapAndDepositData The data outlining the conditions for the swap and across deposit when calling the periphery contract.
     */
    function _callSwapAndBridge(SpokePoolV3PeripheryInterface.SwapAndDepositData calldata swapAndDepositData) internal {
        // Load relevant variables on the stack.
        IERC20 _swapToken = IERC20(swapAndDepositData.swapToken);
        uint256 _swapTokenAmount = swapAndDepositData.swapTokenAmount;

        _swapToken.safeTransferFrom(msg.sender, address(this), _swapTokenAmount);
        _swapToken.forceApprove(address(SPOKE_POOL_PERIPHERY), _swapTokenAmount);
        SPOKE_POOL_PERIPHERY.swapAndBridge(swapAndDepositData);
    }
}

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
contract SpokePoolV3Periphery is SpokePoolV3PeripheryInterface, Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    V3SpokePoolInterface public spokePool;

    // Wrapped native token contract address.
    WETH9Interface public wrappedNativeToken;

    // Canonical Permit2 contract address.
    IPermit2 public permit2;

    // Address of the proxy contract that users should interact with to call this contract.
    // Force users to call through this contract to make sure they don't leave any approvals/permits
    // outstanding on this contract that could be abused because this contract executes arbitrary
    // calldata.
    address public proxy;

    // Nonce for this contract to use for EIP1271 "signatures".
    uint48 private eip1271Nonce;

    // Boolean indicating whether the contract is initialized.
    bool private initialized;

    // Slot for checking whether this contract is expecting a callback from permit2. Used to confirm whether it should return a valid signature response.
    // When solidity 0.8.24 becomes more widely available, this should be replaced with a TSTORE caching method.
    bool private expectingPermit2Callback;

    // EIP 1271 magic bytes indicating a valid signature.
    bytes4 private constant EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    // EIP 1271 bytes indicating an invalid signature.
    bytes4 private constant EIP1271_INVALID_SIGNATURE = 0xffffffff;

    event SwapBeforeBridge(
        address exchange,
        bytes exchangeCalldata,
        address indexed swapToken,
        address indexed acrossInputToken,
        uint256 swapTokenAmount,
        uint256 acrossInputAmount,
        address indexed acrossOutputToken,
        uint256 acrossOutputAmount
    );

    /****************************************
     *                ERRORS                *
     ****************************************/
    error InvalidPermit2();
    error ContractInitialized();
    error InvalidSignatureLength();
    error MinimumExpectedInputAmount();
    error LeftoverSrcTokens();
    error InvalidMsgValue();
    error InvalidSpokePool();
    error InvalidProxy();
    error InvalidSwapToken();
    error NotProxy();

    /**
     * @notice Construct a new Proxy contract.
     * @dev Is empty and all of the state variables are initialized in the initialize function
     * to allow for deployment at a deterministic address via create2, which requires that the bytecode
     * across different networks is the same. Constructor parameters affect the bytecode so we can only
     * add parameters here that are consistent across networks.
     */
    constructor() {}

    /**
     * @notice Initializes the SwapAndBridgeBase contract.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     * @param _wrappedNativeToken Address of the wrapped native token for the network this contract is deployed to.
     * @param _proxy Address of the proxy contract that users should interact with to call this contract.
     * @param _permit2 Address of the deployed network's canonical permit2 contract.
     * @dev These values are initialized in a function and not in the constructor so that the creation code of this contract
     * is the same across networks with different addresses for the wrapped native token and this network's
     * corresponding spoke pool contract. This is to allow this contract to be deterministically deployed with CREATE2.
     */
    function initialize(
        V3SpokePoolInterface _spokePool,
        WETH9Interface _wrappedNativeToken,
        address _proxy,
        IPermit2 _permit2
    ) external nonReentrant {
        if (initialized) revert ContractInitialized();
        initialized = true;

        if (!address(_spokePool).isContract()) revert InvalidSpokePool();
        spokePool = _spokePool;
        wrappedNativeToken = _wrappedNativeToken;
        if (!_proxy.isContract()) revert InvalidProxy();
        proxy = _proxy;
        if (!address(_permit2).isContract()) revert InvalidPermit2();
        permit2 = _permit2;
    }

    /**
     * @notice Passthrough function to `depositV3()` on the SpokePool contract.
     * @dev Protects the caller from losing their ETH (or other native token) by reverting if the SpokePool address
     * they intended to call does not exist on this chain. Because this contract can be deployed at the same address
     * everywhere callers should be protected even if the transaction is submitted to an unintended network.
     * This contract should only be used for native token deposits, as this problem only exists for native tokens.
     * @param recipient Address to receive funds at on destination chain.
     * @param inputToken Token to lock into this contract to initiate deposit.
     * @param inputAmount Amount of tokens to deposit.
     * @param outputAmount Amount of tokens to receive on destination chain.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param exclusiveRelayer Address of the relayer who has exclusive rights to fill this deposit. Can be set to
     * 0x0 if no period is desired. If so, then must set exclusivityParameter to 0.
     * @param exclusivityParameter Timestamp or offset, after which any relayer can fill this deposit. Must set
     * to 0 if exclusiveRelayer is set to 0x0, and vice versa.
     * @param fillDeadline Timestamp after which this deposit can no longer be filled.
     */
    function deposit(
        address recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable override nonReentrant {
        if (msg.value != inputAmount) revert InvalidMsgValue();
        if (!address(spokePool).isContract()) revert InvalidSpokePool();
        // Set msg.sender as the depositor so that msg.sender can speed up the deposit.
        spokePool.depositV3{ value: msg.value }(
            msg.sender,
            recipient,
            inputToken,
            // @dev Setting outputToken to 0x0 to instruct fillers to use the equivalent token
            // as the originToken on the destination chain.
            address(0),
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityParameter,
            message
        );
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If msg.value is 0, then this function is only callable by the proxy contract, to protect against
     * approval abuse attacks where a user has set an approval on this contract to spend any ERC20 token.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapAndDepositData Specifies the data needed to perform a swap on a generic exchange.
     */
    function swapAndBridge(SwapAndDepositData calldata swapAndDepositData) external payable override nonReentrant {
        // If a user performs a swapAndBridge with the swap token as the native token, wrap the value and treat the rest of transaction
        // as though the user deposited a wrapped native token.
        if (msg.value != 0) {
            if (msg.value != swapAndDepositData.swapTokenAmount) revert InvalidMsgValue();
            if (address(swapAndDepositData.swapToken) != address(wrappedNativeToken)) revert InvalidSwapToken();
            wrappedNativeToken.deposit{ value: msg.value }();
        } else {
            // If swap requires an approval to this contract, then force user to go through proxy
            // to prevent their approval from being abused.
            _calledByProxy();
            IERC20(swapAndDepositData.swapToken).safeTransferFrom(
                msg.sender,
                address(this),
                swapAndDepositData.swapTokenAmount
            );
        }
        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If the swapToken in swapData does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithPermit(
        SwapAndDepositData calldata swapAndDepositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(permitSignature);
        // Load variables used in this function onto the stack.
        address _swapToken = swapAndDepositData.swapToken;
        uint256 _swapTokenAmount = swapAndDepositData.swapTokenAmount;

        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try IERC20Permit(_swapToken).permit(msg.sender, address(this), _swapTokenAmount, deadline, v, r, s) {} catch {}
        IERC20(_swapToken).safeTransferFrom(msg.sender, address(this), _swapTokenAmount);

        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @notice Uses permit2 to transfer tokens from a user before swapping a token on this chain via specified router and submitting an Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param signatureOwner The owner of the permit2 signature and depositor for the Across spoke pool.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param permit The permit data signed over by the owner.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function swapAndBridgeWithPermit2(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external override nonReentrant {
        bytes32 witness = PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData);
        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: swapAndDepositData.swapTokenAmount
        });

        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            signatureOwner,
            witness,
            PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING,
            signature
        );
        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @notice Swaps an EIP-3009 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param swapAndDepositData Specifies the params we need to perform a swap on a generic exchange.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded adepositors (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithAuthorization(
        SwapAndDepositData calldata swapAndDepositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(receiveWithAuthSignature);
        // While any contract can vacuously implement `transferWithAuthorization` (or just have a fallback),
        // if tokens were not sent to this contract, by this call to swapData.swapToken, this function will revert
        // when attempting to swap tokens it does not own.
        IERC20Auth(address(swapAndDepositData.swapToken)).receiveWithAuthorization(
            msg.sender,
            address(this),
            swapAndDepositData.swapTokenAmount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param depositData Specifies the Across deposit params to send.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithPermit(
        DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(permitSignature);
        // Load variables used in this function onto the stack.
        address _inputToken = depositData.baseDepositData.inputToken;
        uint256 _inputAmount = depositData.inputAmount;

        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try IERC20Permit(_inputToken).permit(msg.sender, address(this), _inputAmount, deadline, v, r, s) {} catch {}
        IERC20(_inputToken).safeTransferFrom(msg.sender, address(this), _inputAmount);

        _depositV3(
            depositData.baseDepositData.depositor,
            depositData.baseDepositData.recipient,
            _inputToken,
            depositData.baseDepositData.outputToken,
            _inputAmount,
            depositData.baseDepositData.outputAmount,
            depositData.baseDepositData.destinationChainId,
            depositData.baseDepositData.exclusiveRelayer,
            depositData.baseDepositData.quoteTimestamp,
            depositData.baseDepositData.fillDeadline,
            depositData.baseDepositData.exclusivityParameter,
            depositData.baseDepositData.message
        );
    }

    /**
     * @notice Uses permit2 to transfer and submit an Across deposit to the Spoke Pool contract.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param signatureOwner The owner of the permit2 signature and depositor for the Across spoke pool.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param permit The permit data signed over by the owner.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function depositWithPermit2(
        address signatureOwner,
        DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external override nonReentrant {
        bytes32 witness = PeripherySigningLib.hashDepositData(depositData);
        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: depositData.inputAmount
        });

        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            signatureOwner,
            witness,
            PeripherySigningLib.EIP712_DEPOSIT_TYPE_STRING,
            signature
        );
        _depositV3(
            depositData.baseDepositData.depositor,
            depositData.baseDepositData.recipient,
            depositData.baseDepositData.inputToken,
            depositData.baseDepositData.outputToken,
            depositData.inputAmount,
            depositData.baseDepositData.outputAmount,
            depositData.baseDepositData.destinationChainId,
            depositData.baseDepositData.exclusiveRelayer,
            depositData.baseDepositData.quoteTimestamp,
            depositData.baseDepositData.fillDeadline,
            depositData.baseDepositData.exclusivityParameter,
            depositData.baseDepositData.message
        );
    }

    /**
     * @notice Deposits an EIP-3009 compliant Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param depositData Specifies the Across deposit params to send.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithAuthorization(
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external override nonReentrant {
        // Load variables used multiple times onto the stack.
        uint256 _inputAmount = depositData.inputAmount;

        // Redeem the receiveWithAuthSignature.
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(receiveWithAuthSignature);
        IERC20Auth(depositData.baseDepositData.inputToken).receiveWithAuthorization(
            msg.sender,
            address(this),
            _inputAmount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );

        _depositV3(
            depositData.baseDepositData.depositor,
            depositData.baseDepositData.recipient,
            depositData.baseDepositData.inputToken,
            depositData.baseDepositData.outputToken,
            _inputAmount,
            depositData.baseDepositData.outputAmount,
            depositData.baseDepositData.destinationChainId,
            depositData.baseDepositData.exclusiveRelayer,
            depositData.baseDepositData.quoteTimestamp,
            depositData.baseDepositData.fillDeadline,
            depositData.baseDepositData.exclusivityParameter,
            depositData.baseDepositData.message
        );
    }

    /**
     * @notice Verifies that the signer is the owner of the signing contract.
     * @dev The _hash and _signature fields are intentionally ignored since this contract will accept
     * any signature which originated from permit2 after the call to the exchange.
     * @dev This is safe since this contract should never hold funds nor approvals, other than when it is depositing or swapping.
     */
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4 magicBytes) {
        magicBytes = (msg.sender == address(permit2) && expectingPermit2Callback)
            ? EIP1271_VALID_SIGNATURE
            : EIP1271_INVALID_SIGNATURE;
    }

    /**
     * @notice Approves the spoke pool and calls `depositV3` function with the specified input parameters.
     * @param depositor The address on the origin chain which should be treated as the depositor by Across, and will therefore receive refunds if this deposit
     * is unfilled.
     * @param recipient The address on the destination chain which should receive outputAmount of outputToken.
     * @param inputToken The token to deposit on the origin chain.
     * @param outputToken The token to receive on the destination chain.
     * @param inputAmount The amount of the input token to deposit.
     * @param outputAmount The amount of the output token to receive.
     * @param destinationChainId The network ID for the destination chain.
     * @param exclusiveRelayer The optional address for an Across relayer which may fill the deposit exclusively.
     * @param quoteTimestamp The timestamp at which the relay and LP fee was calculated.
     * @param fillDeadline The timestamp at which the deposit must be filled before it will be refunded by Across.
     * @param exclusivityParameter The deadline or offset during which the exclusive relayer has rights to fill the deposit without contention.
     * @param message The message to execute on the destination chain.
     */
    function _depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) private {
        IERC20(inputToken).forceApprove(address(spokePool), inputAmount);
        spokePool.depositV3(
            depositor,
            recipient,
            inputToken, // input token
            outputToken, // output token
            inputAmount, // input amount.
            outputAmount, // output amount
            destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityParameter,
            message
        );
    }

    /**
     * @notice Swaps a token on the origin chain before depositing into the Across spoke pool atomically.
     * @param swapAndDepositData The parameters to use when calling both the swap on an exchange and bridging via an Across spoke pool.
     */
    function _swapAndBridge(SwapAndDepositData calldata swapAndDepositData) private {
        // Load variables we use multiple times onto the stack.
        IERC20 _swapToken = IERC20(swapAndDepositData.swapToken);
        IERC20 _acrossInputToken = IERC20(swapAndDepositData.depositData.inputToken);
        TransferType _transferType = swapAndDepositData.transferType;
        address _exchange = swapAndDepositData.exchange;
        uint256 _swapTokenAmount = swapAndDepositData.swapTokenAmount;

        // Swap and run safety checks.
        uint256 srcBalanceBefore = _swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = _acrossInputToken.balanceOf(address(this));

        // The exchange will either receive funds from this contract via a direct transfer, an approval to spend funds on this contract, or via an
        // EIP1271 permit2 signature.
        if (_transferType == TransferType.Approval) _swapToken.forceApprove(_exchange, _swapTokenAmount);
        else if (_transferType == TransferType.Transfer) _swapToken.transfer(_exchange, _swapTokenAmount);
        else {
            _swapToken.forceApprove(address(permit2), _swapTokenAmount);
            expectingPermit2Callback = true;
            permit2.permit(
                address(this), // owner
                IPermit2.PermitSingle({
                    details: IPermit2.PermitDetails({
                        token: address(_swapToken),
                        amount: uint160(_swapTokenAmount),
                        expiration: uint48(block.timestamp),
                        nonce: eip1271Nonce++
                    }),
                    spender: _exchange,
                    sigDeadline: block.timestamp
                }), // permitSingle
                "0x" // signature is unused. The only verification for a valid signature is if we are at this code block.
            );
            expectingPermit2Callback = false;
        }
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = _exchange.call(swapAndDepositData.routerCalldata);
        require(success, string(result));

        // Sanity check that we received as many tokens as we require:
        uint256 returnAmount = _acrossInputToken.balanceOf(address(this)) - dstBalanceBefore;

        // Sanity check that received amount from swap is enough to submit Across deposit with.
        if (returnAmount < swapAndDepositData.minExpectedInputTokenAmount) revert MinimumExpectedInputAmount();
        // Sanity check that we don't have any leftover swap tokens that would be locked in this contract (i.e. check
        // that we weren't partial filled).
        if (srcBalanceBefore - _swapToken.balanceOf(address(this)) != _swapTokenAmount) revert LeftoverSrcTokens();

        emit SwapBeforeBridge(
            _exchange,
            swapAndDepositData.routerCalldata,
            address(_swapToken),
            address(_acrossInputToken),
            _swapTokenAmount,
            returnAmount,
            swapAndDepositData.depositData.outputToken,
            swapAndDepositData.depositData.outputAmount
        );

        // Deposit the swapped tokens into Across and bridge them using remainder of input params.
        _depositV3(
            swapAndDepositData.depositData.depositor,
            swapAndDepositData.depositData.recipient,
            address(_acrossInputToken),
            swapAndDepositData.depositData.outputToken,
            returnAmount,
            swapAndDepositData.depositData.outputAmount,
            swapAndDepositData.depositData.destinationChainId,
            swapAndDepositData.depositData.exclusiveRelayer,
            swapAndDepositData.depositData.quoteTimestamp,
            swapAndDepositData.depositData.fillDeadline,
            swapAndDepositData.depositData.exclusivityParameter,
            swapAndDepositData.depositData.message
        );
    }

    /**
     * @notice Function to check that the msg.sender is the initialized proxy contract.
     */
    function _calledByProxy() internal view {
        if (msg.sender != proxy) revert NotProxy();
    }
}
