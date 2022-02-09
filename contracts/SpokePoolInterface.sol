//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./MerkleLib.sol";

interface SpokePoolInterface {
    function setCrossDomainAdmin(address newCrossDomainAdmin) external;

    function setHubPool(address newHubPool) external;

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) external;

    function setDepositQuoteTimeBuffer(uint64 buffer) external;

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) external;

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        MerkleLib.DestinationDistribution memory distributionLeaf,
        bytes32[] memory inclusionProof
    ) external;
}
