// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Contains common data structures and functions used by all SpokePool implementations.
 */
interface SpokePoolInterface {
    // Stores collection of merkle roots that can be published to this contract from the HubPool, which are referenced
    // by "data workers" via inclusion proofs to execute leaves in the roots.
    struct RootBundle {
        // Merkle root of slow relays that were not fully filled and whose recipient is still owed funds from the LP pool.
        bytes32 slowRelayRoot;
        // Merkle root of relayer refunds for successful relays.
        bytes32 relayerRefundRoot;
        // This is a 2D bitmap tracking which leaves in the relayer refund root have been claimed, with max size of
        // 256x(2^248) leaves per root.
        mapping(uint256 => uint256) claimedBitmap;
    }

    function setCrossDomainAdmin(address newCrossDomainAdmin) external;

    function setHubPool(address newHubPool) external;

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) external;

    function pauseDeposits(bool pause) external;

    function pauseFills(bool pause) external;

    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot) external;

    function emergencyDeleteRootBundle(uint256 rootBundleId) external;

    function chainId() external view returns (uint256);

    error NotEOA();
}
