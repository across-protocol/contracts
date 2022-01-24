//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

contract HubPool {
    //   constructor() {}

    function deposit(
        address originToken,
        uint256 amount,
        address recipient,
        uint256 destinationChainId,
        uint256 relayerFee
    ) public {}

    function initiateRelay(
        uint256 originChain,
        address sender,
        uint256 amount,
        address recipient,
        uint256 relayerFee,
        uint256 realizedLpFee
    ) public {}

    function fillRelay(
        uint256 relayId,
        uint256 fillAmount,
        uint256 repaymentChain
    ) public {}

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) public {}

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        uint256 leafId,
        address l2TokenAddress,
        uint256 netSendAmount,
        address[] memory relayerRefundAddresses,
        uint256[] memory relayerRefundAmounts,
        bytes32[] memory inclusionProof
    ) public {}
}
