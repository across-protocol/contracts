// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/AdapterInterface.sol";

interface HubPoolInterface {
    struct PoolRebalanceLeaf {
        // Used as the index in the bitmap to track whether this leaf has been executed or not.
        uint256 leafId;
        // This is used to know which chain to send cross-chain transactions to (and which SpokePool to sent to).
        uint256 chainId;
        // The following arrays are required to be the same length. They are parallel arrays for the given chainId and should be ordered by the `l1Tokens` field.
        // All whitelisted tokens with nonzero relays on this chain in this bundle in the order of whitelisting.
        address[] l1Tokens;
        uint256[] bundleLpFees; // Total LP fee amount per token in this bundle, encompassing all associated bundled relays.
        // This array is grouped with the two above, and it represents the amount to send or request back from the
        // SpokePool. If positive, the pool will pay the SpokePool. If negative the SpokePool will pay the HubPool.
        // There can be arbitrarily complex rebalancing rules defined offchain. This number is only nonzero
        // when the rules indicate that a rebalancing action should occur. When a rebalance does not occur,
        // runningBalances for this token should change by the total relays - deposits in this bundle. When a rebalance
        // does occur, runningBalances should be set to zero for this token and the netSendAmounts should be set to the
        // previous runningBalances + relays - deposits in this bundle.
        int256[] netSendAmounts;
        // This is only here to be emitted in an event to track a running unpaid balance between the L2 pool and the L1 pool.
        // A positive number indicates that the HubPool owes the SpokePool funds. A negative number indicates that the
        // SpokePool owes the HubPool funds. See the comment above for the dynamics of this and netSendAmounts
        int256[] runningBalances;
    }

    function setBond(IERC20 newBondToken, uint256 newBondAmount) external;

    function setCrossChainContracts(
        uint256 l2ChainId,
        address adapter,
        address spokePool
    ) external;

    function whitelistRoute(
        uint256 destinationChainId,
        address originToken,
        address destinationToken
    ) external;

    function enableL1TokenForLiquidityProvision(address l1Token, bool isWeth) external;

    function disableL1TokenForLiquidityProvision(address l1Token) external;

    function addLiquidity(address l1Token, uint256 l1TokenAmount) external payable;

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) external;

    function exchangeRateCurrent(address l1Token) external returns (uint256);

    function liquidityUtilizationPostRelay(address token, uint256 relayedAmount) external returns (uint256);

    function initiateRelayerRefund(
        uint256[] memory bundleEvaluationBlockNumbers,
        uint64 poolRebalanceLeafLeafCount,
        bytes32 poolRebalanceRoot,
        bytes32 destinationDistributionRoot,
        bytes32 slowRelayFulfillmentRoot
    ) external;

    function executeRelayerRefund(PoolRebalanceLeaf memory poolRebalanceLeafLeaf, bytes32[] memory proof) external;

    function disputeRelayerRefund() external;
}
