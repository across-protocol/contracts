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

// TODO: should this just be an array of TypedData? E.g. funding type enum + whatever data is needed to pull that funding
// TODO: user is not signing over any of these (e.g. if doing gasless, so decoupling doesn't matter here)
// Note: for TWA funding, a user submitting an order should make sure to select `Uniqueness` param that would enforce orderId
// uniqueness, since witness == TWA nonce
struct Funding {
    bytes fundingCommands; // restricted funding-only commands; gasless orderOwner auth also proves namespace auth
    TypedData fundingInputs; // hashable command inputs, excluding signatures / permits / auth payloads
    TypedData authorizationData; // signatures / permits / auth payloads, excluded from ids and witnesses
}

struct Order {
    address orderOwner;
    TypedData pathOrMerkleRoot;
    TypedData refundSettings;
    Uniqueness uniqueness;
}

struct PathResolution {
    // TODO: how to represent the two below more compactly when a plaintext Path is selected by the user?
    Path path;
    bytes32[] pathProof; // empty when pathOrMerkleRoot directly specifies a single raw Path
    // Note: sometimes, a submitter wants this emitted to Prove their right to e.g. get sponsorship repayment
    bool emitPathId;
}

struct SubmitterInputs {
    PathResolution pathResolution;
    Funding funding;
    bytes executorData; // submitter-authored blob handed to Executor with the resolved path
}

interface IOrderGateway {
    function submit(
        Order calldata order,
        Funding calldata orderOwnerFunding,
        SubmitterInputs calldata submitterInputs
    ) external payable;
}

library USDFreeIdLib {
    // TODO: this will come from a EIP-712 lib
    function domainHash(uint32 chainId, address contractAddr) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFree.Domain.V1", chainId, contractAddr));
    }

    function orderId(bytes32 domainH, Order calldata order) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    // TODO: not V5 lol
                    "USDFreeIds.OrderId.V5",
                    domainH,
                    // TODO: lol what. `_orderHash` already includes both orderOwner and order.uniqueness
                    // TODO: I think here we have two options:
                    // TODO: 1. just have _orderHash() and that's it
                    // TODO: 2. have explicit commitments like: `orderPlanHash (pathOrMerkleRoot), orderOwner, refundSettings, uniqueness`
                    _orderHash(order),
                    order.orderOwner,
                    _nonceForId(order.uniqueness)
                )
            );
    }

    function executionId(
        bytes32 orderId_,
        SubmitterInputs calldata submitterInputs,
        address submitter
    ) internal pure returns (bytes32) {
        return
            keccak256(
                // TODO: above, we call that `_orderHash`. Why here it's a `_submitterPlanHash`? Be consistent.
                // TODO: also, why no nonce here? We might want a nonce that submitter provides too (e.g. for TWA-like
                // TODO: submitter uniqueness). This might be overkill
                abi.encode("USDFreeIds.ExecutionId.V3", orderId_, _submitterPlanHash(submitterInputs), submitter)
            );
    }

    // TODO: this is extremely expensive to calculate. Take pathLeaf as a 2nd argument here, this will only be used at
    // TODO: the time of Merkle root resolution
    function pathId(bytes32 orderId_, Path calldata path) internal pure returns (bytes32) {
        return keccak256(abi.encode("USDFreeIds.PathId.V1", orderId_, _pathHash(path)));
    }

    // TODO: lol, do we need this extra stuff? Can this just be orderId?
    function orderOwnerFundingWitness(bytes32 orderId_) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.OrderOwnerFunding.V1", orderId_));
    }

    // TODO: same as above
    function submitterFundingWitness(bytes32 executionId_) internal pure returns (bytes32) {
        return keccak256(abi.encode("GWWitnessLib.SubmitterFunding.V1", executionId_));
    }

    function _orderHash(Order calldata order) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.Order.V1",
                    order.orderOwner,
                    _typedDataHash(order.pathOrMerkleRoot),
                    _typedDataHash(order.refundSettings),
                    _uniquenessHash(order.uniqueness)
                )
            );
    }

    function _submitterPlanHash(SubmitterInputs calldata submitterInputs) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.SubmitterPlan.V3",
                    _pathHash(submitterInputs.pathResolution.path),
                    submitterInputs.pathResolution.emitPathId,
                    // TODO: interesting: submitter is committing to the fundingPlan. This is different from `orderOwner`,
                    // TODO: We should decide on a common way to do this for both: either both commit to some plan and then
                    // TODO: supply sigs separately, or both just supply sigs that tie to the order commands itself, without
                    // TODO: commiting to other funding types and sources (that are parallel to this current funding. E.g.
                    // TODO: a submitter can still commit to user's funding, even with sigs)
                    _fundingPlanHash(submitterInputs.funding),
                    keccak256(submitterInputs.executorData)
                )
            );
    }

    function _fundingPlanHash(Funding calldata funding) private pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    "USDFree.FundingPlan.V2",
                    keccak256(funding.fundingCommands),
                    _typedDataHash(funding.fundingInputs)
                )
            );
    }

    function _pathHash(Path calldata path) private pure returns (bytes32) {
        return keccak256(abi.encode(_stepHash(path.step), keccak256(path.next)));
    }

    function _stepHash(Step calldata step) private pure returns (bytes32) {
        return keccak256(abi.encode(step.executor, keccak256(step.message)));
    }

    function _typedDataHash(TypedData calldata typedData) private pure returns (bytes32) {
        return keccak256(abi.encode(typedData.typ, keccak256(typedData.data)));
    }

    function _uniquenessHash(Uniqueness calldata uniqueness) private pure returns (bytes32) {
        return keccak256(abi.encode("USDFree.Uniqueness.V1", uniqueness.enforce, uniqueness.nonce));
    }

    function _nonceForId(Uniqueness calldata uniqueness) private pure returns (bytes32) {
        return uniqueness.enforce ? uniqueness.nonce : bytes32(0);
    }
}
