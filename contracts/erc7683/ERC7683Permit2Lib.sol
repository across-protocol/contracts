// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import { GaslessCrossChainOrder } from "./ERC7683.sol";

// Data unique to every CrossChainOrder settled on Across
struct AcrossOrderData {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputAmount;
    uint256 destinationChainId;
    bytes32 recipient;
    address exclusiveRelayer;
    /// @notice User needs to be careful not to re-use a deposit nonce when depositing into Across otherwise the
    /// user risks their deposit being unfillable. See @across/contracts/SpokePool.sol#unsafeDeposit() for
    /// more details on this situation.
    uint256 depositNonce;
    uint32 exclusivityPeriod;
    bytes message;
}

struct AcrossOriginFillerData {
    address exclusiveRelayer;
}

struct AcrossDestinationFillerData {
    uint256 repaymentChainId;
}

bytes constant ACROSS_ORDER_DATA_TYPE = abi.encodePacked(
    "AcrossOrderData(",
    "address inputToken,",
    "uint256 inputAmount,",
    "address outputToken,",
    "uint256 outputAmount,",
    "uint256 destinationChainId,",
    "bytes32 recipient,",
    "address exclusiveRelayer,"
    "uint256 depositNonce,",
    "uint32 exclusivityPeriod,",
    "bytes message)"
);

bytes32 constant ACROSS_ORDER_DATA_TYPE_HASH = keccak256(ACROSS_ORDER_DATA_TYPE);

/**
 * @notice ERC7683Permit2Lib knows how to process a particular type of external Permit2Order so that it can be used in Across.
 * @dev This library is responsible for definining the ERC712 type strings/hashes and performing hashes on the types.
 * @custom:security-contact bugs@across.to
 */
library ERC7683Permit2Lib {
    bytes internal constant GASLESS_CROSS_CHAIN_ORDER_TYPE =
        abi.encodePacked(
            "GaslessCrossChainOrder(",
            "address originSettler,",
            "address user,",
            "uint256 nonce,",
            "uint256 originChainId,",
            "uint32 openDeadline,",
            "uint32 fillDeadline,",
            "bytes32 orderDataType,",
            "AcrossOrderData orderData)"
        );

    bytes internal constant GASLESS_CROSS_CHAIN_ORDER_EIP712_TYPE =
        abi.encodePacked(GASLESS_CROSS_CHAIN_ORDER_TYPE, ACROSS_ORDER_DATA_TYPE);
    bytes32 internal constant GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH = keccak256(GASLESS_CROSS_CHAIN_ORDER_EIP712_TYPE);

    string private constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant PERMIT2_ORDER_TYPE =
        string(
            abi.encodePacked(
                "GaslessCrossChainOrder witness)",
                ACROSS_ORDER_DATA_TYPE,
                GASLESS_CROSS_CHAIN_ORDER_TYPE,
                TOKEN_PERMISSIONS_TYPE
            )
        );

    // Hashes an order to get an order hash. Needed for permit2.
    function hashOrder(GaslessCrossChainOrder memory order, bytes32 orderDataHash) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    GASLESS_CROSS_CHAIN_ORDER_TYPE_HASH,
                    order.originSettler,
                    order.user,
                    order.nonce,
                    order.originChainId,
                    order.openDeadline,
                    order.fillDeadline,
                    order.orderDataType,
                    orderDataHash
                )
            );
    }

    function hashOrderData(AcrossOrderData memory orderData) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    ACROSS_ORDER_DATA_TYPE_HASH,
                    orderData.inputToken,
                    orderData.inputAmount,
                    orderData.outputToken,
                    orderData.outputAmount,
                    orderData.destinationChainId,
                    orderData.recipient,
                    orderData.exclusiveRelayer,
                    orderData.depositNonce,
                    orderData.exclusivityPeriod,
                    keccak256(orderData.message)
                )
            );
    }
}
