//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface SpokePoolInterface {
    function crossDomainAdmin() external returns (address);

    function setCrossDomainAdmin(address newCrossDomainAdmin) external;

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enable
    ) external;

    function setDepositQuoteTimeBuffer(uint64 buffer) external;

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) external;
}
