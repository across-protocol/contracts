// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualImplementation } from "../../interfaces/ICounterfactualImplementation.sol";
import { NATIVE_ASSET, BPS_SCALAR } from "./CounterfactualConstants.sol";
import { ChainConfig } from "./ChainConfig.sol";
import { SPOKE_POOL_ID, WRAPPED_NATIVE_ID } from "./ChainConfigIds.sol";

/**
 * @notice Route parameters committed to in the merkle leaf.
 * @dev `inputTokenId` is a chain-agnostic id resolved against the registry at execute time
 *      (see ChainConfigIds.sol). `outputToken` stays as a raw bytes32 since it lives on the
 *      destination chain and is opaque to the source-chain registry.
 */
struct SpokePoolDepositParams {
    uint256 destinationChainId;
    uint32 inputTokenId;
    bytes32 outputToken;
    bytes32 recipient;
    bytes message;
    uint256 stableExchangeRate;
    uint256 maxFeeFixed;
    uint256 maxFeeBps;
    uint256 executionFee;
}

/**
 * @notice Data supplied by the submitter at execution time.
 */
struct SpokePoolSubmitterData {
    uint256 inputAmount;
    uint256 outputAmount;
    bytes32 exclusiveRelayer;
    uint32 exclusivityDeadline;
    address executionFeeRecipient;
    uint32 quoteTimestamp;
    uint32 fillDeadline;
    uint32 signatureDeadline;
    bytes signature;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation contract for counterfactual deposits via Across SpokePool.
 * @dev Chain-agnostic: same bytecode + same constructor arg (registry) → same deterministic address
 *      on every EVM chain. The SpokePool address, EIP-712 signer, and wrapped-native token are
 *      resolved from `ChainConfig` at execute time.
 *
 *      Called via delegatecall from the CounterfactualDeposit dispatcher. EIP-712 domain separator
 *      uses `address(this)` (the clone address) to prevent cross-clone replay attacks. No nonce is
 *      needed: token balance is consumed on execution (natural replay protection), and short
 *      deadlines bound the window.
 *
 *      The EIP-712 `ExecuteDeposit` typehash binds `inputTokenId`, so a signature issued for one
 *      input token cannot be replayed against a leaf naming a different `inputTokenId` even if
 *      both leaves share this implementation in the same clone.
 *
 *      Depositor-driven speed-ups are not supported: the `depositor` passed to `SpokePool.deposit()`
 *      is `address(this)` (the clone), which has no private key and does not implement EIP-1271,
 *      and therefore cannot sign `speedUpV3Deposit` messages.
 * @custom:security-contact bugs@across.to
 */
contract CounterfactualDepositSpokePool is ICounterfactualImplementation, EIP712 {
    using SafeERC20 for IERC20;

    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /**
     * @notice Emitted after a SpokePool deposit is successfully executed.
     */
    event SpokePoolDepositExecuted(
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 indexed exclusiveRelayer,
        uint32 exclusivityDeadline,
        address indexed executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    );

    error MaxFee();
    error InvalidSignature();
    error SignatureExpired();
    error NativeTransferFailed();
    error RegistryUnset(uint32 id);

    /// @notice EIP-712 typehash for execute deposit signature verification. `inputTokenId` is
    ///         included so a signer authorization cannot be replayed across leaves naming
    ///         different input tokens.
    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint32 inputTokenId,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );

    /// @notice Chain-local config registry. Same address on every chain.
    ChainConfig public immutable registry;

    constructor(address _registry) EIP712("CounterfactualDepositSpokePool", "v1.0.0") {
        registry = ChainConfig(_registry);
    }

    /**
     * @inheritdoc ICounterfactualImplementation
     * @dev Deposits into the Across SpokePool. `params` is ABI-encoded as `SpokePoolDepositParams`;
     *      `submitterData` as `SpokePoolSubmitterData` (includes an EIP-712 signature from the
     *      registry-configured signer).
     *      Supports native-token deposits when the leaf's `inputTokenId` resolves to the
     *      `NATIVE_ASSET` sentinel. Reverts: `SignatureExpired`, `InvalidSignature`, `MaxFee`,
     *      `NativeTransferFailed`, `RegistryUnset`.
     */
    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        SpokePoolDepositParams memory dp = abi.decode(params, (SpokePoolDepositParams));
        SpokePoolSubmitterData memory sd = abi.decode(submitterData, (SpokePoolSubmitterData));

        if (block.timestamp > sd.signatureDeadline) revert SignatureExpired();
        _verifySignature(dp.inputTokenId, sd);

        address inputToken = _requireRegistryAddress(registry.tokens(dp.inputTokenId), dp.inputTokenId);
        address spokePool = _requireRegistryAddress(registry.bridges(SPOKE_POOL_ID), SPOKE_POOL_ID);

        uint256 depositAmount = sd.inputAmount - dp.executionFee;

        _checkFee(dp, sd.inputAmount, sd.outputAmount, depositAmount);

        bool isNative = inputToken == NATIVE_ASSET;

        bytes32 spokePoolInputToken;
        if (isNative) {
            address wrappedNative = _requireRegistryAddress(registry.tokens(WRAPPED_NATIVE_ID), WRAPPED_NATIVE_ID);
            spokePoolInputToken = bytes32(uint256(uint160(wrappedNative)));
        } else {
            IERC20(inputToken).forceApprove(spokePool, depositAmount);
            spokePoolInputToken = bytes32(uint256(uint160(inputToken)));
        }

        V3SpokePoolInterface(spokePool).deposit{ value: isNative ? depositAmount : 0 }(
            bytes32(uint256(uint160(address(this)))),
            dp.recipient,
            spokePoolInputToken,
            dp.outputToken,
            depositAmount,
            sd.outputAmount,
            dp.destinationChainId,
            sd.exclusiveRelayer,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.exclusivityDeadline,
            dp.message
        );

        // Pay execution fee
        if (dp.executionFee > 0) {
            if (isNative) {
                (bool success, ) = sd.executionFeeRecipient.call{ value: dp.executionFee }("");
                if (!success) revert NativeTransferFailed();
            } else {
                IERC20(inputToken).safeTransfer(sd.executionFeeRecipient, dp.executionFee);
            }
        }

        emit SpokePoolDepositExecuted(
            sd.inputAmount,
            sd.outputAmount,
            sd.exclusiveRelayer,
            sd.exclusivityDeadline,
            sd.executionFeeRecipient,
            sd.quoteTimestamp,
            sd.fillDeadline,
            sd.signatureDeadline
        );
    }

    function _checkFee(
        SpokePoolDepositParams memory dp,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 depositAmount
    ) private pure {
        uint256 outputInInputToken = (outputAmount * dp.stableExchangeRate) / EXCHANGE_RATE_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + dp.executionFee;
        uint256 maxFee = dp.maxFeeFixed + (dp.maxFeeBps * inputAmount) / BPS_SCALAR;
        if (totalFee > maxFee) revert MaxFee();
    }

    function _verifySignature(uint32 inputTokenId, SpokePoolSubmitterData memory sd) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputTokenId,
                sd.inputAmount,
                sd.outputAmount,
                sd.exclusiveRelayer,
                sd.exclusivityDeadline,
                sd.quoteTimestamp,
                sd.fillDeadline,
                sd.signatureDeadline
            )
        );
        address signer = registry.spokePoolSigner();
        if (signer == address(0)) revert InvalidSignature();
        if (ECDSA.recover(_hashTypedDataV4(structHash), sd.signature) != signer) revert InvalidSignature();
    }

    function _requireRegistryAddress(address resolved, uint32 id) private pure returns (address) {
        if (resolved == address(0)) revert RegistryUnset(id);
        return resolved;
    }
}
