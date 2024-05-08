// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../external/interfaces/IPermit2.sol";
import { CrossChainOrder } from "./ERC7683Depositor.sol";

/**
 * @notice Permit2OrderLib knows how to process a particular type of external Permit2Order so that it can be used in Across.
 * @dev This library is responsible for validating the order and communicating with Permit2 to pull the tokens in.
 * This is a library to allow it to be pulled directly into the SpokePool in a future version.
 */
library Permit2OrderLib {
    // Errors
    error WrongSettlerContract();
    error AfterDeadline();
    error MultipleOutputsNotAllowed();

    // Type strings and hashes
    bytes private constant OUTPUT_TOKEN_TYPE =
        "OutputToken(address recipient,address token,uint256 amount,uint256 chainId)";
    bytes32 private constant OUTPUT_TOKEN_TYPE_HASH = keccak256(OUTPUT_TOKEN_TYPE);

    bytes internal constant ORDER_TYPE =
        abi.encodePacked(
            "CrossChainOrder(",
            "address settlerContract,",
            "address swapper,",
            "uint256 nonce,",
            "uint32 originChainId,",
            "uint32 initiateDeadline,",
            "uint32 fillDeadline,",
            "bytes orderData)"
        );
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(ORDER_TYPE);
    string private constant TOKEN_PERMISSIONS_TYPE = "TokenPermissions(address token,uint256 amount)";
    string internal constant PERMIT2_ORDER_TYPE =
        string(abi.encodePacked("CrossChainOrder witness)", ORDER_TYPE, TOKEN_PERMISSIONS_TYPE));

    // Hashes an order to get an order hash. Needed for permit2.
    function hashOrder(CrossChainOrder memory order) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    ORDER_TYPE_HASH,
                    order.settlementContract,
                    order.swapper,
                    order.nonce,
                    order.originChainId,
                    order.initiateDeadline,
                    order.fillDeadline,
                    keccak256(order.orderData)
                )
            );
    }
}
