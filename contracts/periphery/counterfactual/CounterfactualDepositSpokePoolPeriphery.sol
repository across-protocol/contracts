// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SpokePoolPeripheryInterface } from "../../interfaces/SpokePoolPeripheryInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { AddressToBytes32 } from "../../libraries/AddressConverters.sol";
import { BPS_SCALAR } from "./CounterfactualConstants.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
 */
struct SpokePoolPeripheryDepositParams {
    uint256 destinationChainId;
    bytes32 inputToken; // Post-swap token deposited into SpokePool
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    address swapToken; // Token the user sends to the clone (pre-swap)
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
    uint256 executionFee; // In swapToken, paid to relayer
    bool enableProportionalAdjustment;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct SpokePoolPeripherySubmitterData {
    uint256 swapTokenAmount;
    uint256 outputAmount;
    uint256 minExpectedInputTokenAmount;
    address exchange;
    SpokePoolPeripheryInterface.TransferType transferType;
    bytes routerCalldata;
    bytes32 exclusiveRelayer;
    uint32 exclusivityParameter;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePoolPeriphery
 * @notice Implementation contract for counterfactual deposits via SpokePoolPeriphery (swap + bridge).
 * @dev Called via delegatecall from the CounterfactualDeposit dispatcher. EIP-712 domain separator uses
 *      `address(this)` (the clone address) to prevent cross-clone replay attacks. No nonce is needed:
 *      token balance is consumed on execution (natural replay protection), and short deadlines bound the window.
 *
 *      The user sends `swapToken` to the predicted clone address. At execution time, the relayer triggers
 *      a swap via SpokePoolPeriphery before depositing the resulting token into SpokePool for cross-chain bridging.
 *
 *      Native token (ETH) swaps are not supported. Users with ETH should use CounterfactualDepositSpokePool directly.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePoolPeriphery is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;

    /**
     * @notice Emitted after a SpokePoolPeriphery swap+deposit is successfully executed.
     */
    event SpokePoolPeripheryDepositExecuted(
        uint256 swapTokenAmount,
        uint256 outputAmount,
        uint256 minExpectedInputTokenAmount,
        address indexed exchange,
        bytes32 indexed exclusiveRelayer,
        uint32 exclusivityParameter,
        address indexed executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();

    /// @notice EIP-712 typehash for execute swap+deposit signature verification.
    bytes32 public constant EXECUTE_SWAP_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteSwapDeposit(uint256 swapTokenAmount,uint256 outputAmount,uint256 minExpectedInputTokenAmount,address exchange,uint8 transferType,bytes32 routerCalldataHash,bytes32 exclusiveRelayer,uint32 exclusivityParameter,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );

    /// @notice SpokePoolPeriphery contract for swap + bridge operations
    address public immutable spokePoolPeriphery;

    /// @notice Across SpokePool contract (passed through to periphery)
    address public immutable spokePool;

    /// @notice Signer that authorizes execution parameters
    address public immutable signer;

    constructor(
        address _spokePoolPeriphery,
        address _spokePool,
        address _signer
    ) EIP712("CounterfactualDepositSpokePoolPeriphery", "v1.0.0") {
        spokePoolPeriphery = _spokePoolPeriphery;
        spokePool = _spokePool;
        signer = _signer;
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Swaps and deposits via SpokePoolPeriphery. `params` is ABI-encoded as `SpokePoolPeripheryDepositParams`;
     *      `submitterData` as `SpokePoolPeripherySubmitterData` (includes an EIP-712 signature from `signer`).
     *      Reverts: `SignatureExpired`, `InvalidSignature`, `MaxFee`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        SpokePoolPeripheryDepositParams memory dp = abi.decode(params, (SpokePoolPeripheryDepositParams));
        SpokePoolPeripherySubmitterData memory sd = abi.decode(submitterData, (SpokePoolPeripherySubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifySignature(sd);

        uint256 swapAmount = sd.swapTokenAmount - dp.executionFee;

        _checkFee(dp, sd.swapTokenAmount);

        // Pay execution fee to relayer.
        if (dp.executionFee > 0) {
            IERC20(dp.swapToken).safeTransfer(sd.executionFeeRecipient, dp.executionFee);
        }

        // Approve periphery to pull swap tokens.
        IERC20(dp.swapToken).forceApprove(spokePoolPeriphery, swapAmount);

        // Build SwapAndDepositData and execute swap + bridge via periphery.
        SpokePoolPeripheryInterface(spokePoolPeriphery).swapAndBridge(
            SpokePoolPeripheryInterface.SwapAndDepositData({
                submissionFees: SpokePoolPeripheryInterface.Fees({ amount: 0, recipient: address(0) }),
                depositData: SpokePoolPeripheryInterface.BaseDepositData({
                    inputToken: address(uint160(uint256(dp.inputToken))),
                    outputToken: dp.outputToken,
                    outputAmount: sd.outputAmount,
                    depositor: address(this),
                    recipient: dp.recipient,
                    destinationChainId: dp.destinationChainId,
                    exclusiveRelayer: sd.exclusiveRelayer,
                    quoteTimestamp: sd.quoteTimestamp,
                    fillDeadline: sd.fillDeadline,
                    exclusivityParameter: sd.exclusivityParameter,
                    message: dp.message
                }),
                swapToken: dp.swapToken,
                exchange: sd.exchange,
                transferType: sd.transferType,
                swapTokenAmount: swapAmount,
                minExpectedInputTokenAmount: sd.minExpectedInputTokenAmount,
                routerCalldata: sd.routerCalldata,
                enableProportionalAdjustment: dp.enableProportionalAdjustment,
                spokePool: spokePool,
                nonce: 0
            })
        );

        emit SpokePoolPeripheryDepositExecuted(
            sd.swapTokenAmount,
            sd.outputAmount,
            sd.minExpectedInputTokenAmount,
            sd.exchange,
            sd.exclusiveRelayer,
            sd.exclusivityParameter,
            sd.executionFeeRecipient,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.signatureDeadline
        );
    }

    function _checkFee(SpokePoolPeripheryDepositParams memory dp, uint256 swapTokenAmount) private pure {
        uint256 maxFee = dp.maxFeeFixed + (dp.maxFeeBps * swapTokenAmount) / BPS_SCALAR;
        if (dp.executionFee > maxFee) revert MaxFee();
    }

    function _verifySignature(SpokePoolPeripherySubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_SWAP_DEPOSIT_TYPEHASH,
                sd.swapTokenAmount,
                sd.outputAmount,
                sd.minExpectedInputTokenAmount,
                sd.exchange,
                sd.transferType,
                keccak256(sd.routerCalldata),
                sd.exclusiveRelayer,
                sd.exclusivityParameter,
                sd.quoteTimestamp,
                sd.fillDeadline,
                sd.signatureDeadline
            )
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.signature) != signer) revert InvalidSignature();
    }
}
