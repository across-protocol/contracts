// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Contains common data structures and functions used by all SpokePool implementations.
 */
interface MockV2SpokePoolInterface {
    struct RelayData {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 destinationToken;
        uint256 amount;
        uint256 originChainId;
        uint256 destinationChainId;
        int64 realizedLpFeePct;
        int64 relayerFeePct;
        uint32 depositId;
        bytes message;
    }

    struct RelayExecution {
        RelayData relay;
        bytes32 relayHash;
        int64 updatedRelayerFeePct;
        bytes32 updatedRecipient;
        bytes updatedMessage;
        uint256 repaymentChainId;
        uint256 maxTokensToSend;
        uint256 maxCount;
        bool slowFill;
        int256 payoutAdjustmentPct;
    }

    struct SlowFill {
        RelayData relayData;
        int256 payoutAdjustmentPct;
    }
}
