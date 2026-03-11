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

struct Path {
    Step step;
    bytes next; // interpreted by next step entrypoint contract (e.g. ~DstOFTHandler)
}

struct Uniqueness {
    bool enforce;
    bytes32 nonce; // if !enforce, nonce is ignored for id generation and uniqueness checks
}

struct FundingPlan {
    bytes fundingCommands; // restricted funding-only commands
    TypedData fundingInputs; // command inputs excluding signatures / permits / auth payloads
}

struct FundingExecution {
    FundingPlan plan;
    TypedData authorizationData; // signatures / permits / auth payloads consumed by funding commands
}

struct Order {
    address orderOwner;
    TypedData pathOrMerkleRoot;
    TypedData refundSettings;
    Uniqueness uniqueness;
}

struct SubmitterInputs {
    TypedData pathResolution; // resolves pathOrMerkleRoot into a concrete path when a Merkle root was supplied
    FundingExecution funding;
}

interface IOrderGateway {
    function submit(
        Order calldata order,
        FundingExecution calldata orderOwnerFunding,
        SubmitterInputs calldata submitterInputs
    ) external payable;
}

library USDFreeHashes {
    function stepHash(Step calldata step) internal pure returns (bytes32) {
        return keccak256(abi.encode(step.executor, keccak256(step.message)));
    }

    function typedDataHash(TypedData calldata typedData) internal pure returns (bytes32) {
        return keccak256(abi.encode(typedData.typ, keccak256(typedData.data)));
    }

    function pathHash(Path calldata path) internal pure returns (bytes32) {
        return keccak256(abi.encode(stepHash(path.step), keccak256(path.next)));
    }

    function uniquenessHash(Uniqueness calldata uniqueness) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFree.Uniqueness.V1", uniqueness.enforce, uniqueness.nonce));
    }

    function fundingPlanHash(FundingPlan calldata fundingPlan) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.FundingPlan.V1",
                    keccak256(fundingPlan.fundingCommands),
                    typedDataHash(fundingPlan.fundingInputs)
                )
            );
    }

    function nonceForId(Uniqueness calldata uniqueness) internal pure returns (bytes32) {
        return uniqueness.enforce ? uniqueness.nonce : bytes32(0);
    }

    function orderHash(Order calldata order) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.Order.V1",
                    order.orderOwner,
                    typedDataHash(order.pathOrMerkleRoot),
                    typedDataHash(order.refundSettings),
                    uniquenessHash(order.uniqueness)
                )
            );
    }

    function submitterPlanHash(
        bytes32 orderH,
        SubmitterInputs calldata submitterInputs
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.SubmitterPlan.V1",
                    orderH,
                    typedDataHash(submitterInputs.pathResolution),
                    fundingPlanHash(submitterInputs.funding.plan)
                )
            );
    }

    function domainHash(uint32 chainId, address contractAddr) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFree.Domain.V1", chainId, contractAddr));
    }
}

library USDFreeIds {
    function orderId(
        bytes32 domainH,
        bytes32 orderH,
        address orderOwner,
        bytes32 nonceOrZero
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFreeIds.OrderId.V4", domainH, orderH, orderOwner, nonceOrZero));
    }

    function executionId(bytes32 orderId_, bytes32 submitterPlanH, address submitter) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFreeIds.ExecutionId.V1", orderId_, submitterPlanH, submitter));
    }
}

library GWWitnessLib {
    function orderOwnerFundingWitness(bytes32 orderId_) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.OrderOwnerFunding.V1", orderId_));
    }

    function submitterFundingWitness(bytes32 executionId_) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.SubmitterFunding.V1", executionId_));
    }
}
