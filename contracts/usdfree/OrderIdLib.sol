// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

library OrderIdLib {
    bytes32 internal constant ORDER_ID_TYPEHASH =
        keccak256("OrderId(bytes32 domainHash,uint8 fundingType,address funder,bytes32 orderHash,bytes32 salt)");

    function orderId(
        bytes32 _domainHash,
        uint8 fundingType,
        address funder,
        bytes32 orderHash,
        // Note: `saltOrNonce` can be used to produce a unique orderId. It can also be used to make some cryptographic commitments
        bytes32 saltOrNonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(ORDER_ID_TYPEHASH, _domainHash, fundingType, funder, orderHash, saltOrNonce));
    }
}
