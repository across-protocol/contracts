// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "./Permit2Order.sol";
import "../external/interfaces/IPermit2.sol";

/**
 * @notice Permit2OrderLib knows how to process a particular type of external Permit2Order so that it can be used in Across.
 * @dev This library is responsible for validating the order and communicating with Permit2 to pull the tokens in.
 * This is a library to allow it to be pulled directly into the SpokePool in a future version.
 */
library Permit2OrderLib {
    // Errors
    error WrongSettlerContract();
    error AfterDeadline();
    error ValidationContractNotAllowed();
    error MultipleOutputsNotAllowed();
    error InputAndCollateralNotEqual();

    // Type strings and hashes
    bytes private constant OUTPUT_TOKEN_TYPE =
        "OutputToken(address recipient,address token,uint256 amount,uint256 chainId)";
    bytes32 private constant OUTPUT_TOKEN_TYPE_HASH = keccak256(OUTPUT_TOKEN_TYPE);

    bytes internal constant ORDER_TYPE =
        abi.encodePacked(
            "CrossChainLimitOrder(",
            "address settlerContract,",
            "address offerer,",
            "uint256 nonce,",
            "uint256 initiateDeadline,",
            "uint256 fillPeriod",
            "uint32 challengePeriod",
            "uint32 proofPeriod",
            "address settlementOracle",
            "uint256 validationContract,",
            "uint256 validationData,",
            "address inputToken,",
            "uint256 inputAmount,",
            "address collateralToken,",
            "uint256 collateralAmount,",
            "OutputToken[] outputs)",
            OUTPUT_TOKEN_TYPE
        );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);
    string private constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant PERMIT2_ORDER_TYPE =
        string(abi.encodePacked("CrossChainLimitOrder witness)", ORDER_TYPE, TOKEN_PERMISSIONS_TYPE));

    // Hashes a single output.
    function _hashOutput(OutputToken memory output) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(OUTPUT_TOKEN_TYPE_HASH, output.recipient, output.token, output.amount, output.chainId)
            );
    }

    // Hashes the output array. Since we only allow a single output, it just grabs the first element.
    function _hashOutputs(OutputToken[] memory outputs) internal pure returns (bytes32) {
        // Across only allows a single output, so only hash
        return keccak256(abi.encodePacked(_hashOutput(outputs[0])));
    }

    // Hashes an order to get an order hash. Needed for permit2.
    function _hashOrder(CrossChainLimitOrder memory order) internal pure returns (bytes32) {
        bytes memory part1 = abi.encode(
            ORDER_TYPE_HASH,
            order.info.settlerContract,
            order.info.offerer,
            order.info.nonce,
            order.info.initiateDeadline,
            order.info.fillPeriod,
            order.info.challengePeriod,
            order.info.proofPeriod,
            order.info.settlementOracle,
            order.info.validationContract,
            keccak256(order.info.validationData),
            order.input.token,
            order.input.amount
        );

        // avoid stack too deep
        bytes memory part2 = abi.encode(
            order.fillerCollateral.token,
            order.fillerCollateral.amount,
            order.challengerCollateral.token,
            order.challengerCollateral.amount,
            _hashOutputs(order.outputs)
        );

        return keccak256(abi.encodePacked(part1, part2));
    }

    function _processPermit2Order(IPermit2 permit2, SignedOrder calldata signedOrder)
        internal
        returns (CrossChainLimitOrder memory)
    {
        CrossChainLimitOrder memory limitOrder = abi.decode(signedOrder.order, (CrossChainLimitOrder));

        if (address(this) != limitOrder.info.settlerContract) revert WrongSettlerContract();
        if (block.timestamp > limitOrder.info.initiateDeadline) revert AfterDeadline();
        if (limitOrder.info.validationContract != address(0)) revert ValidationContractNotAllowed();
        if (limitOrder.outputs.length != 1) revert MultipleOutputsNotAllowed();
        if (limitOrder.fillerCollateral.token != limitOrder.input.token) revert InputAndCollateralNotEqual();

        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: limitOrder.input.token, amount: limitOrder.input.maxAmount }),
            nonce: limitOrder.info.nonce,
            deadline: limitOrder.info.initiateDeadline
        });

        IPermit2.SignatureTransferDetails memory signatureTransferDetails = IPermit2.SignatureTransferDetails({
            to: address(this),
            requestedAmount: limitOrder.input.amount
        });

        // Pull user funds.
        permit2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            limitOrder.info.offerer,
            _hashOrder(limitOrder),
            PERMIT2_ORDER_TYPE,
            signedOrder.sig
        );

        // Pull filler collateral.
        IPermit2(address(permit2)).transferFrom(
            msg.sender,
            address(this),
            uint160(limitOrder.fillerCollateral.amount),
            limitOrder.fillerCollateral.token
        );

        return limitOrder;
    }
}
