// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import { CrossChainOrder } from "./ERC7683.sol";

// Data unique to every CrossChainOrder settled on Across
struct AcrossOrderData {
    address inputToken;
    uint256 inputAmount;
    address outputToken;
    uint256 outputAmount;
    uint32 destinationChainId;
    address recipient;
    uint32 exclusivityDeadlineOffset;
    bytes message;
}

struct AcrossFillerData {
    address exclusiveRelayer;
}

/**
 * @notice ERC7683Permit2Lib knows how to process a particular type of external Permit2Order so that it can be used in Across.
 * @dev This library is responsible for definining the ERC712 type strings/hashes and performing hashes on the types.
 */
library ERC7683Permit2Lib {
    bytes private constant ACROSS_ORDER_DATA_TYPE =
        abi.encodePacked(
            "AcrossOrderData(",
            "address inputToken,",
            "uint256 inputAmount,",
            "address outputToken,",
            "uint256 outputAmount,",
            "uint32 destinationChainId,",
            "address recipient,",
            "uint32 exclusivityDeadlineOffset,",
            "bytes message)"
        );

    bytes32 private constant ACROSS_ORDER_DATA_TYPE_HASH = keccak256(ACROSS_ORDER_DATA_TYPE);

    bytes internal constant CROSS_CHAIN_ORDER_TYPE =
        abi.encodePacked(
            "CrossChainOrder(",
            "address settlerContract,",
            "address swapper,",
            "uint256 nonce,",
            "uint32 originChainId,",
            "uint32 initiateDeadline,",
            "uint32 fillDeadline,",
            "AcrossOrderData orderData)",
            ACROSS_ORDER_DATA_TYPE
        );
    bytes32 internal constant CROSS_CHAIN_ORDER_TYPE_HASH = keccak256(CROSS_CHAIN_ORDER_TYPE);
    string private constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant PERMIT2_ORDER_TYPE =
        string(abi.encodePacked("CrossChainOrder witness)", CROSS_CHAIN_ORDER_TYPE, TOKEN_PERMISSIONS_TYPE));

    // Hashes an order to get an order hash. Needed for permit2.
    function hashOrder(CrossChainOrder memory order, bytes32 orderDataHash) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CROSS_CHAIN_ORDER_TYPE_HASH,
                    order.settlementContract,
                    order.swapper,
                    order.nonce,
                    order.originChainId,
                    order.initiateDeadline,
                    order.fillDeadline,
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
                    orderData.exclusivityDeadlineOffset,
                    keccak256(orderData.message)
                )
            );
    }
}
