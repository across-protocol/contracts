// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface V5SpokePoolInterface {
    /// @notice Thrown when a V5 deposit or fill is attempted outside of a V5 entrypoint / live Gateway execution.
    error V5RequiresGateway();
    /// @notice Thrown when a slow fill is attempted against a V5 deposit (V5 deposits are Gateway-fill-only).
    error V5MethodNotAllowed();
    /// @notice Thrown when submitter provided output amount is less than min output amount from user.
    error V5OutputAmountTooLow();
    /// @notice Thrown when native value is sent but there is no executor callback to forward it to, which would
    /// otherwise strand the value in the SpokePool.
    error V5UnusedMsgValue();
    /// @notice Thrown when relayer passes an invalid message
    error V5InvalidMessage();
    /// @notice Thrown when a V5 deposit is attempted while no Gateway execution is active (no current submitter).
    error InactiveV5Flow();
    /// @notice Thrown when a JIT modification of `outputAmount` would worsen the recipient's terms.
    error ParamModificationNotAnImprovement();
    /// @notice Thrown when the authority signature over the JIT modifications is missing or invalid.
    error InvalidParamModificationSignature();

    /// @notice Discriminates the action encoded in the `input` payload of `adapterExecuteAcrossV5`.
    /// @dev `input` is `abi.encodePacked(bytes1(uint8(action)), abi.encode(actionInput))`: the leading byte selects the
    /// action and the remainder is the action-specific payload — `V5DepositInput`/`V5DepositJit` for `Deposit`,
    /// `V5FillInput`/`V5FillJit` for `Fill`.
    enum V5AdapterAction {
        Deposit,
        Fill
    }

    struct V5FillInput {
        bytes32 recipient;
        bytes32 outputToken;
        uint256 minOutputAmount;
        bytes executorInput;
    }

    struct V5FillJit {
        bytes32 depositor;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        uint256 repaymentChainId;
        bytes32 repaymentAddress;
        bytes message;
        bytes executorJitInput;
    }

    /// @notice Deposit parameters the Executor ABI-encodes into the `input` payload of `adapterExecuteAcrossV5`.
    struct V5DepositInput {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes32 exclusiveRelayer;
        uint256 depositNonce;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityParameter;
        bytes32 dstStepId;
        // Deposit modification rules. Packing: (high 12 bytes for modify permisison flags, low 20 bytes for signing authority if required)
        // Current flags: bit 0: outputAmount, bit 1: exclusiveRelayer, bit 2: exclusivityParameter
        bytes32 paramModificationRules;
    }

    /// @notice Just-in-time modification values the Executor ABI-encodes into the `jitData` payload of
    /// `adapterExecuteAcrossV5`, applied subject to `V5DepositInput.paramModificationRules`.
    struct V5DepositJit {
        uint256 newAmtOut;
        bytes32 newExclusiveRelayer;
        uint32 newExclusivityParameter;
        bytes signature;
    }
}
