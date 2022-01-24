//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

contract HubPool {
    //   constructor() {}

    function addLiquidity(address token, uint256 amount) public {}

    function removeLiquidity(address token, uint256 amount) public {}

    function exchangeRateCurrent(address token) public returns (uint256) {}

    function liquidityUtilizationPostRelay(address token, uint256 relayedAmount) public returns (uint256) {}

    function initiateRelayerRefund(
        uint256[] memory bundleEvaluationBlockNumberForChain,
        bytes32 chainBatchRepaymentProof,
        bytes32 relayerRepaymentDistributionProof
    ) public {}

    function executeRelayerRefund(
        uint256 relayerRefundRequestId,
        uint256 leafId,
        uint256 repaymentChainId,
        address[] memory l1TokenAddress,
        uint256[] memory accumulatedLpFees,
        uint256[] memory netSendAmounts,
        bytes32[] memory inclusionProof
    ) public {}
}
