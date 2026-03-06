// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct Step {
    address executor;
    bytes message; // interpreted by Executor
}

struct TypedData {
    uint8 typ;
    bytes data;
}

enum PathType {
    Single,
    Merkle
}

// =Blueprint
struct Path {
    Step step;
    bytes next; // interpreted by next step entrypoint contract (e.g. ~DstOFTHandler)
}

struct MerklePaths {
    bytes32 root;
}

struct Order {
    TypedData path; // interpreted by OrderGateway as Path / MerklePaths. Path passed to Executor
    TypedData refundSettings; // interpreted by OrderGateway (recipient, reverseDeadline)
    TypedData funding; // interpreted by OrderGateway (e.g. can be of type SingleApproval, SinglePermit2, SingleTWA, MultipleFundings)
}

struct SubmitterInputs {
    TypedData inputs; // interpreted by OrderGateway(if MerklePaths), later by Executor
    TypedData funding; // interpreted by OrderGateway
}

interface OrderGateway {
    function submit(Order calldata order, SubmitterInputs calldata inputs) external payable;
}

library USDFreeHashes {
    function orderHash(Order calldata order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    function pathHash(Path calldata path) internal pure returns (bytes32) {
        return keccak256(abi.encode(path));
    }

    function typedDataHash(TypedData calldata typedData) internal pure returns (bytes32) {
        return keccak256(abi.encode(typedData));
    }

    // TODO: is it really domain if it doesn't have a typehash / type string name prepended?
    function domainHash(uint32 chainId, address contractAddr) internal pure returns (bytes32) {
        return keccak256(abi.encode(chainId, contractAddr));
    }
}

library USDFreeIds {
    function orderId(bytes32 domainH, bytes32 orderH) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFreeIds.OrderId.V1", domainH, orderH));
    }

    function sponsorshipId(bytes32 domainH, bytes32 orderH) internal pure returns (bytes32) {
        return orderId(domainH, orderH);
    }
}

// Gateway witness lib
library GWWitnessLib {
    function orderFundingWitness(bytes32 domainH, bytes32 pathH) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.OrderFunding.V1", domainH, pathH));
    }

    function submitterFundingWitness(bytes32 domainH, bytes32 orderH, bytes32 inputsH) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.SubmitterFunding.V1", domainH, orderH, inputsH));
    }
}
