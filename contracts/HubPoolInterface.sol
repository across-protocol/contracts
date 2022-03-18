// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AdapterInterface.sol";

/**
 * @notice Concise list of functions in HubPool implementation.
 */
interface HubPoolInterface {
    // This leaf is meant to be decoded in the HubPool to rebalance tokens between HubPool and SpokePool.
    struct PoolRebalanceLeaf {
        // This is used to know which chain to send cross-chain transactions to (and which SpokePool to sent to).
        uint256 chainId;
        // Total LP fee amount per token in this bundle, encompassing all associated bundled relays.
        uint256[] bundleLpFees;
        // This array is grouped with the two above, and it represents the amount to send or request back from the
        // SpokePool. If positive, the pool will pay the SpokePool. If negative the SpokePool will pay the HubPool.
        // There can be arbitrarily complex rebalancing rules defined offchain. This number is only nonzero when the
        // rules indicate that a rebalancing action should occur. When a rebalance does occur, runningBalances should be
        // set to zero for this token and the netSendAmounts should be set to the previous runningBalances + relays -
        // deposits in this bundle. If non-zero then it must be set on the SpokePool's RelayerRefundLeaf amountToReturn
        // as -1 * this value to indicate if funds are being sent from or to the SpokePool.
        int256[] netSendAmounts;
        // This is only here to be emitted in an event to track a running unpaid balance between the L2 pool and the L1 pool.
        // A positive number indicates that the HubPool owes the SpokePool funds. A negative number indicates that the
        // SpokePool owes the HubPool funds. See the comment above for the dynamics of this and netSendAmounts
        int256[] runningBalances;
        // Used by data worker to mark which leaves should relay roots to SpokePools, and to otherwise organize leaves.
        // For example, each leaf should contain all the rebalance information for a single chain, but in the case where
        // the list of l1Tokens is very large such that they all can't fit into a single leaf that can be executed under
        // the block gas limit, then the data worker can use this groupIndex to organize them. Any leaves with
        // a groupIndex equal to 0 will relay roots to the SpokePool, so the data worker should ensure that only one
        // leaf for a specific chainId should have a groupIndex equal to 0.
        uint256 groupIndex;
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint8 leafId;
        // The following arrays are required to be the same length. They are parallel arrays for the given chainId and
        // should be ordered by the l1Tokens field. All whitelisted tokens with nonzero relays on this chain in this
        // bundle in the order of whitelisting.
        address[] l1Tokens;
    }

    function setPaused(bool pause) external;

    function emergencyDeleteProposal() external;

    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) external;

    function setProtocolFeeCapture(address newProtocolFeeCaptureAddress, uint256 newProtocolFeeCapturePct) external;

    function setBond(IERC20 newBondToken, uint256 newBondAmount) external;

    function setLiveness(uint32 newLiveness) external;

    function setIdentifier(bytes32 newIdentifier) external;

    function setCrossChainContracts(
        uint256 l2ChainId,
        address adapter,
        address spokePool
    ) external;

    function whitelistRoute(
        uint256 originChainId,
        uint256 destinationChainId,
        address originToken,
        address destinationToken,
        bool enableRoute
    ) external;

    function enableL1TokenForLiquidityProvision(address l1Token) external;

    function disableL1TokenForLiquidityProvision(address l1Token) external;

    function addLiquidity(address l1Token, uint256 l1TokenAmount) external payable;

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) external;

    function exchangeRateCurrent(address l1Token) external returns (uint256);

    function liquidityUtilizationCurrent(address l1Token) external returns (uint256);

    function liquidityUtilizationPostRelay(address token, uint256 relayedAmount) external returns (uint256);

    function sync(address l1Token) external;

    function proposeRootBundle(
        uint256[] memory bundleEvaluationBlockNumbers,
        uint8 poolRebalanceLeafCount,
        bytes32 poolRebalanceRoot,
        bytes32 relayerRefundRoot,
        bytes32 slowRelayRoot
    ) external;

    function executeRootBundle(
        uint256 chainId,
        uint256 groupIndex,
        uint256[] memory bundleLpFees,
        int256[] memory netSendAmounts,
        int256[] memory runningBalances,
        uint8 leafId,
        address[] memory l1Tokens,
        bytes32[] memory proof
    ) external;

    function disputeRootBundle() external;

    function claimProtocolFeesCaptured(address l1Token) external;

    function getRootBundleProposalAncillaryData() external view returns (bytes memory ancillaryData);

    function whitelistedRoute(
        uint256 originChainId,
        address originToken,
        uint256 destinationChainId
    ) external view returns (address);

    function loadEthForL2Calls() external payable;
}
