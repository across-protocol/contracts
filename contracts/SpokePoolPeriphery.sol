// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "./interfaces/V3SpokePoolInterface.sol";
import { IERC20Auth } from "./external/interfaces/IERC20Auth.sol";
import { WETH9Interface } from "./external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "./external/interfaces/IPermit2.sol";
import { PeripherySigningLib } from "./libraries/PeripherySigningLib.sol";
import { SpokePoolPeripheryInterface } from "./interfaces/SpokePoolPeripheryInterface.sol";
import { AddressToBytes32 } from "./libraries/AddressConverters.sol";

/**
 * @title SwapProxy
 * @notice A dedicated proxy contract that isolates swap execution to mitigate frontrunning vulnerabilities.
 * The SpokePoolPeriphery transfers tokens to this contract, which performs the swap and returns tokens back to the periphery.
 * @custom:security-contact bugs@across.to
 */
contract SwapProxy is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    // Canonical Permit2 contract address
    IPermit2 public immutable permit2;

    // EIP 1271 magic bytes indicating a valid signature.
    bytes4 private constant EIP1271_VALID_SIGNATURE = 0x1626ba7e;

    // EIP 1271 bytes indicating an invalid signature.
    bytes4 private constant EIP1271_INVALID_SIGNATURE = 0xffffffff;

    // Mapping from (token, spender) to nonce for Permit2 operations
    mapping(address => mapping(address => uint48)) private permit2Nonces;

    // Slot for checking whether this contract is expecting a callback from permit2. Used to confirm whether it should return a valid signature response.
    bool private expectingPermit2Callback;

    // Errors
    error SwapFailed();
    error UnsupportedTransferType();
    error InvalidExchange();

    /**
     * @notice Constructs a new SwapProxy.
     * @param _permit2 Address of the canonical permit2 contract.
     */
    constructor(address _permit2) {
        permit2 = IPermit2(_permit2);
    }

    /**
     * @notice Executes a swap on the given exchange with the provided calldata.
     * @param inputToken The token to swap from
     * @param outputToken The token to swap to
     * @param inputAmount The amount of input tokens to swap
     * @param exchange The exchange to perform the swap
     * @param transferType The method of transferring tokens to the exchange
     * @param routerCalldata The calldata to execute on the exchange
     * @return outputAmount The actual amount of output tokens received from the swap
     */
    function performSwap(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        address exchange,
        SpokePoolPeripheryInterface.TransferType transferType,
        bytes calldata routerCalldata
    ) external nonReentrant returns (uint256 outputAmount) {
        // Prevent nonce invalidation attack by disallowing exchange to be the permit2 address
        if (exchange == address(permit2)) revert InvalidExchange();

        // We'll return the final balance of output tokens

        // The exchange will either receive funds from this contract via:
        // 1. A direct approval to spend funds on this contract (TransferType.Approval),
        // 2. A direct transfer of funds to the exchange (TransferType.Transfer), or
        // 3. A permit2 approval (TransferType.Permit2Approval)
        if (transferType == SpokePoolPeripheryInterface.TransferType.Approval) {
            IERC20(inputToken).forceApprove(exchange, inputAmount);
        } else if (transferType == SpokePoolPeripheryInterface.TransferType.Transfer) {
            IERC20(inputToken).safeTransfer(exchange, inputAmount);
        } else if (transferType == SpokePoolPeripheryInterface.TransferType.Permit2Approval) {
            IERC20(inputToken).forceApprove(address(permit2), inputAmount);
            expectingPermit2Callback = true;
            permit2.permit(
                address(this), // owner
                IPermit2.PermitSingle({
                    details: IPermit2.PermitDetails({
                        token: inputToken,
                        amount: uint160(inputAmount),
                        expiration: uint48(block.timestamp),
                        nonce: permit2Nonces[inputToken][exchange]++
                    }),
                    spender: exchange,
                    sigDeadline: block.timestamp
                }), // permitSingle
                "" // signature is unused. The only verification for a valid signature is if we are at this code block.
            );
            expectingPermit2Callback = false;
        } else {
            revert UnsupportedTransferType();
        }

        // Execute the swap
        (bool success, ) = exchange.call(routerCalldata);
        if (!success) revert SwapFailed();

        // Get the final output token balance
        uint256 outputBalance = IERC20(outputToken).balanceOf(address(this));

        // Transfer all output tokens back to the periphery
        IERC20(outputToken).safeTransfer(msg.sender, outputBalance);

        // Return the net amount received from the swap
        return outputBalance;
    }

    /**
     * @notice Verifies that the signer is the owner of the signing contract.
     * @dev This function is called by Permit2 during the permit process
     * and we need to return a valid signature result to allow permit2 to succeed.
     */
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4 magicBytes) {
        magicBytes = (msg.sender == address(permit2) && expectingPermit2Callback)
            ? EIP1271_VALID_SIGNATURE
            : EIP1271_INVALID_SIGNATURE;
    }
}

/**
 * @title SpokePoolPeriphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @custom:security-contact bugs@across.to
 */
contract SpokePoolPeriphery is SpokePoolPeripheryInterface, ReentrancyGuard, MultiCaller, EIP712 {
    using SafeERC20 for IERC20;
    using Address for address;
    using AddressToBytes32 for address;

    // Canonical Permit2 contract address.
    IPermit2 public immutable permit2;

    // Swap proxy used for isolating all swap operations
    SwapProxy public immutable swapProxy;

    // Mapping from user address to their current nonce
    mapping(address => uint256) public permitNonces;

    event SwapBeforeBridge(
        address exchange,
        bytes exchangeCalldata,
        address indexed swapToken,
        address indexed acrossInputToken,
        uint256 swapTokenAmount,
        uint256 acrossInputAmount,
        bytes32 indexed acrossOutputToken,
        uint256 acrossOutputAmount
    );

    /****************************************
     *                ERRORS                *
     ****************************************/
    error MinimumExpectedInputAmount();
    error InvalidMsgValue();
    error InvalidSignature();
    error InvalidMinExpectedInputAmount();
    error InvalidNonce();

    /**
     * @notice Construct a new Periphery contract.
     * @param _permit2 Address of the canonical permit2 contract.
     */
    constructor(IPermit2 _permit2) EIP712("ACROSS-PERIPHERY", "1.0.0") {
        require(address(_permit2) != address(0), "Permit2 cannot be zero address");
        require(_isContract(address(_permit2)), "Permit2 must be a contract");
        permit2 = _permit2;

        // Deploy the swap proxy with reference to the permit2 address
        swapProxy = new SwapProxy(address(_permit2));
    }

    /**
     * @inheritdoc SpokePoolPeripheryInterface
     */
    function depositNative(
        address spokePool,
        bytes32 recipient,
        address inputToken,
        uint256 inputAmount,
        bytes32 outputToken,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable override nonReentrant {
        // Set msg.sender as the depositor so that msg.sender can speed up the deposit.
        V3SpokePoolInterface(spokePool).deposit{ value: msg.value }(
            msg.sender.toBytes32(),
            recipient,
            inputToken.toBytes32(),
            outputToken,
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
     * @inheritdoc SpokePoolPeripheryInterface
     * @dev Revert case: When enableProportionalAdjustment is true, the calculation
     * depositData.outputAmount * returnAmount may overflow if the product exceeds 2^256-1,
     * causing immediate transaction revert even when the final division result would fit.
     * This case should be extremely rare as both values would need to be > 1e18 * 1e18.
     * Users will only see a generic failure without explanatory error message.
     * @dev Does not support native tokens as swap output. Only ERC20 tokens can be deposited via this function.
     */
    function swapAndBridge(SwapAndDepositData calldata swapAndDepositData) external payable override nonReentrant {
        // If a user performs a swapAndBridge with the swap token as the native token, wrap the value and treat the rest of transaction
        // as though the user deposited a wrapped native token.
        if (msg.value != 0) {
            if (msg.value != swapAndDepositData.swapTokenAmount) revert InvalidMsgValue();
            // Assume swapToken implements WETH9 interface if sending value
            WETH9Interface(swapAndDepositData.swapToken).deposit{ value: msg.value }();
        } else {
            // Transfer ERC20 tokens from sender to this contract
            IERC20(swapAndDepositData.swapToken).safeTransferFrom(
                msg.sender,
                address(this),
                swapAndDepositData.swapTokenAmount
            );
        }

        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @inheritdoc SpokePoolPeripheryInterface
     * @dev Revert case: When enableProportionalAdjustment is true, the calculation
     * depositData.outputAmount * returnAmount may overflow if the product exceeds 2^256-1,
     * causing immediate transaction revert even when the final division result would fit.
     * This case should be extremely rare as both values would need to be > 1e18 * 1e18.
     * Users will only see a generic failure without explanatory error message.
     * @dev Does not support native tokens as swap output. Only ERC20 tokens can be deposited via this function.
     */
    function swapAndBridgeWithPermit(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        uint256 deadline,
        bytes calldata permitSignature,
        bytes calldata swapAndDepositDataSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(permitSignature);
        // Load variables used in this function onto the stack.
        address _swapToken = swapAndDepositData.swapToken;
        uint256 _swapTokenAmount = swapAndDepositData.swapTokenAmount;
        uint256 _submissionFeeAmount = swapAndDepositData.submissionFees.amount;
        address _submissionFeeRecipient = swapAndDepositData.submissionFees.recipient;
        uint256 _pullAmount = _submissionFeeAmount + _swapTokenAmount;

        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try IERC20Permit(_swapToken).permit(signatureOwner, address(this), _pullAmount, deadline, v, r, s) {} catch {}
        IERC20(_swapToken).safeTransferFrom(signatureOwner, address(this), _pullAmount);
        _paySubmissionFees(_swapToken, _submissionFeeRecipient, _submissionFeeAmount);
        // Verify and increment nonce to prevent replay attacks.
        _validateAndIncrementNonce(signatureOwner, swapAndDepositData.nonce);
        // Verify that the signatureOwner signed the input swapAndDepositData.
        _validateSignature(
            signatureOwner,
            PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData),
            swapAndDepositDataSignature
        );
        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @inheritdoc SpokePoolPeripheryInterface
     * @dev Revert case: When enableProportionalAdjustment is true, the calculation
     * depositData.outputAmount * returnAmount may overflow if the product exceeds 2^256-1,
     * causing immediate transaction revert even when the final division result would fit.
     * This case should be extremely rare as both values would need to be > 1e18 * 1e18.
     * Users will only see a generic failure without explanatory error message.
     * @dev Does not support native tokens as swap output. Only ERC20 tokens can be deposited via this function.
     */
    function swapAndBridgeWithPermit2(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external override nonReentrant {
        bytes32 witness = PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData);
        uint256 _submissionFeeAmount = swapAndDepositData.submissionFees.amount;
        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: swapAndDepositData.swapTokenAmount + _submissionFeeAmount
        });

        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            signatureOwner,
            witness,
            PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING,
            signature
        );
        _paySubmissionFees(
            swapAndDepositData.swapToken,
            swapAndDepositData.submissionFees.recipient,
            _submissionFeeAmount
        );
        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @inheritdoc SpokePoolPeripheryInterface
     * @dev Revert case: When enableProportionalAdjustment is true, the calculation
     * depositData.outputAmount * returnAmount may overflow if the product exceeds 2^256-1,
     * causing immediate transaction revert even when the final division result would fit.
     * This case should be extremely rare as both values would need to be > 1e18 * 1e18.
     * Users will only see a generic failure without explanatory error message.
     * @dev Does not support native tokens as swap output. Only ERC20 tokens can be deposited via this function.
     */
    function swapAndBridgeWithAuthorization(
        address signatureOwner,
        SwapAndDepositData calldata swapAndDepositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata receiveWithAuthSignature,
        bytes calldata swapAndDepositDataSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(receiveWithAuthSignature);
        uint256 _submissionFeeAmount = swapAndDepositData.submissionFees.amount;
        // While any contract can vacuously implement `receiveWithAuthorization` (or just have a fallback),
        // if tokens were not sent to this contract, by this call to swapData.swapToken, this function will revert
        // when attempting to swap tokens it does not own.
        IERC20Auth(address(swapAndDepositData.swapToken)).receiveWithAuthorization(
            signatureOwner,
            address(this),
            swapAndDepositData.swapTokenAmount + _submissionFeeAmount,
            validAfter,
            validBefore,
            bytes32(swapAndDepositData.nonce),
            v,
            r,
            s
        );
        _paySubmissionFees(
            swapAndDepositData.swapToken,
            swapAndDepositData.submissionFees.recipient,
            _submissionFeeAmount
        );

        // Note: No need to validate our internal nonce for receiveWithAuthorization
        // as EIP-3009 has its own nonce mechanism that prevents replay attacks.
        //
        // Design Decision: We reuse the receiveWithAuthorization nonce for our signatures,
        // but not for permit, which creates a theoretical replay attack that we think is
        // incredibly unlikely because this would require:
        // 1. A token implementing both ERC-2612 and ERC-3009
        // 2. A user using the same nonces for swapAndBridgeWithPermit and for swapAndBridgeWithAuthorization
        // 3. Issuing these signatures within a short amount of time (limited by fillDeadlineBuffer)
        // Verify that the signatureOwner signed the input swapAndDepositData.
        _validateSignature(
            signatureOwner,
            PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData),
            swapAndDepositDataSignature
        );
        _swapAndBridge(swapAndDepositData);
    }

    /**
     * @inheritdoc SpokePoolPeripheryInterface
     */
    function depositWithPermit(
        address signatureOwner,
        DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature,
        bytes calldata depositDataSignature
    ) external override nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(permitSignature);
        // Load variables used in this function onto the stack.
        address _inputToken = depositData.baseDepositData.inputToken;
        uint256 _inputAmount = depositData.inputAmount;
        uint256 _submissionFeeAmount = depositData.submissionFees.amount;
        address _submissionFeeRecipient = depositData.submissionFees.recipient;
        uint256 _pullAmount = _submissionFeeAmount + _inputAmount;

        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try IERC20Permit(_inputToken).permit(signatureOwner, address(this), _pullAmount, deadline, v, r, s) {} catch {}
        IERC20(_inputToken).safeTransferFrom(signatureOwner, address(this), _pullAmount);
        _paySubmissionFees(_inputToken, _submissionFeeRecipient, _submissionFeeAmount);

        // Verify and increment nonce to prevent replay attacks.
        _validateAndIncrementNonce(signatureOwner, depositData.nonce);
        // Verify that the signatureOwner signed the input depositData.
        _validateSignature(signatureOwner, PeripherySigningLib.hashDepositData(depositData), depositDataSignature);
        _deposit(
            depositData.spokePool,
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
     * @inheritdoc SpokePoolPeripheryInterface
     */
    function depositWithPermit2(
        address signatureOwner,
        DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        bytes calldata signature
    ) external override nonReentrant {
        bytes32 witness = PeripherySigningLib.hashDepositData(depositData);
        uint256 _submissionFeeAmount = depositData.submissionFees.amount;
        IPermit2.SignatureTransferDetails memory transferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: depositData.inputAmount + _submissionFeeAmount
        });

        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            signatureOwner,
            witness,
            PeripherySigningLib.EIP712_DEPOSIT_TYPE_STRING,
            signature
        );
        _paySubmissionFees(
            depositData.baseDepositData.inputToken,
            depositData.submissionFees.recipient,
            _submissionFeeAmount
        );

        _deposit(
            depositData.spokePool,
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
     * @inheritdoc SpokePoolPeripheryInterface
     */
    function depositWithAuthorization(
        address signatureOwner,
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata receiveWithAuthSignature,
        bytes calldata depositDataSignature
    ) external override nonReentrant {
        // Load variables used multiple times onto the stack.
        uint256 _inputAmount = depositData.inputAmount;
        uint256 _submissionFeeAmount = depositData.submissionFees.amount;

        // Redeem the receiveWithAuthSignature.
        (bytes32 r, bytes32 s, uint8 v) = PeripherySigningLib.deserializeSignature(receiveWithAuthSignature);
        IERC20Auth(depositData.baseDepositData.inputToken).receiveWithAuthorization(
            signatureOwner,
            address(this),
            _inputAmount + _submissionFeeAmount,
            validAfter,
            validBefore,
            bytes32(depositData.nonce),
            v,
            r,
            s
        );
        _paySubmissionFees(
            depositData.baseDepositData.inputToken,
            depositData.submissionFees.recipient,
            _submissionFeeAmount
        );

        // Note: No need to validate our internal nonce for receiveWithAuthorization
        // as EIP-3009 has its own nonce mechanism that prevents replay attacks.
        //
        // Design Decision: We reuse the receiveWithAuthorization nonce for our signatures,
        // but not for permit, which creates a theoretical replay attack that we think is
        // incredibly unlikely because this would require:
        // 1. A token implementing both ERC-2612 and ERC-3009
        // 2. A user using the same nonces for depositWithPermit and for depositWithAuthorization
        // 3. Issuing these signatures within a short amount of time (limited by fillDeadlineBuffer)
        // Verify that the signatureOwner signed the input depositData.
        _validateSignature(signatureOwner, PeripherySigningLib.hashDepositData(depositData), depositDataSignature);
        _deposit(
            depositData.spokePool,
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
     * @notice Returns the contract's EIP712 domain separator, used to sign hashed DepositData/SwapAndDepositData types.
     */
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /**
     * @notice Validates that the typed data hash corresponds to the input signature owner and corresponding signature.
     * @param signatureOwner The alledged signer of the input hash.
     * @param typedDataHash The EIP712 data hash to check the signature against.
     * @param signature The signature to validate.
     */
    function _validateSignature(address signatureOwner, bytes32 typedDataHash, bytes calldata signature) private view {
        if (!SignatureChecker.isValidSignatureNow(signatureOwner, _hashTypedDataV4(typedDataHash), signature)) {
            revert InvalidSignature();
        }
    }

    /**
     * @notice Validates and increments the user's nonce to prevent replay attacks.
     * @param user The user whose nonce is being validated.
     * @param providedNonce The provided nonce value.
     */
    function _validateAndIncrementNonce(address user, uint256 providedNonce) private {
        if (permitNonces[user] != providedNonce) {
            revert InvalidNonce();
        }
        permitNonces[user]++;
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
    function _deposit(
        address spokePool,
        address depositor,
        bytes32 recipient,
        address inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) private {
        IERC20(inputToken).forceApprove(spokePool, inputAmount);
        V3SpokePoolInterface(spokePool).deposit(
            depositor.toBytes32(),
            recipient,
            inputToken.toBytes32(),
            outputToken,
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
     * @notice Swaps a token on the origin chain before depositing into the Across spoke pool atomically.
     * @param swapAndDepositData The parameters to use when calling both the swap on an exchange and bridging via an Across spoke pool.
     */
    function _swapAndBridge(SwapAndDepositData calldata swapAndDepositData) private {
        // Load variables we use multiple times onto the stack.
        IERC20 _swapToken = IERC20(swapAndDepositData.swapToken);
        IERC20 _acrossInputToken = IERC20(swapAndDepositData.depositData.inputToken);
        address _exchange = swapAndDepositData.exchange;
        uint256 _swapTokenAmount = swapAndDepositData.swapTokenAmount;

        // Transfer tokens to the swap proxy for executing the swap
        _swapToken.safeTransfer(address(swapProxy), _swapTokenAmount);

        // Execute the swap via the swap proxy using the appropriate transfer type
        // This function will swap _swapToken for _acrossInputToken and return the amount of _acrossInputToken received
        uint256 returnAmount = swapProxy.performSwap(
            address(_swapToken),
            address(_acrossInputToken),
            _swapTokenAmount,
            _exchange,
            swapAndDepositData.transferType,
            swapAndDepositData.routerCalldata
        );

        // Sanity check that received amount from swap is enough to submit Across deposit with.
        if (returnAmount < swapAndDepositData.minExpectedInputTokenAmount) revert MinimumExpectedInputAmount();

        // Calculate adjusted output amount based on whether proportional adjustment is enabled
        if (swapAndDepositData.minExpectedInputTokenAmount == 0) revert InvalidMinExpectedInputAmount();
        uint256 adjustedOutputAmount;
        if (swapAndDepositData.enableProportionalAdjustment) {
            // Adjust the output amount proportionally based on the returned input amount
            adjustedOutputAmount =
                (swapAndDepositData.depositData.outputAmount * returnAmount) /
                swapAndDepositData.minExpectedInputTokenAmount;
        } else {
            // Use the fixed output amount without adjustment
            adjustedOutputAmount = swapAndDepositData.depositData.outputAmount;
        }

        emit SwapBeforeBridge(
            _exchange,
            swapAndDepositData.routerCalldata,
            address(_swapToken),
            address(_acrossInputToken),
            _swapTokenAmount,
            returnAmount,
            swapAndDepositData.depositData.outputToken,
            adjustedOutputAmount
        );

        // Deposit the swapped tokens into Across and bridge them using remainder of input params.
        _deposit(
            swapAndDepositData.spokePool,
            swapAndDepositData.depositData.depositor,
            swapAndDepositData.depositData.recipient,
            address(_acrossInputToken),
            swapAndDepositData.depositData.outputToken,
            returnAmount,
            adjustedOutputAmount,
            swapAndDepositData.depositData.destinationChainId,
            swapAndDepositData.depositData.exclusiveRelayer,
            swapAndDepositData.depositData.quoteTimestamp,
            swapAndDepositData.depositData.fillDeadline,
            swapAndDepositData.depositData.exclusivityParameter,
            swapAndDepositData.depositData.message
        );
    }

    function _paySubmissionFees(address feeToken, address recipient, uint256 amount) private {
        if (amount > 0) {
            // Use msg.sender as recipient if recipient is zero address, otherwise use the specified recipient
            address feeRecipient = recipient == address(0) ? msg.sender : recipient;
            IERC20(feeToken).safeTransfer(feeRecipient, amount);
        }
    }

    /**
     * @notice Internal function to check if an address is a contract
     * @dev This is a replacement for OpenZeppelin's isContract function which is deprecated
     * @param addr The address to check
     * @return True if the address is a contract, false otherwise
     */
    function _isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
