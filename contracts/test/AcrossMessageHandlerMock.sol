// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "../interfaces/USSSpokePoolInterface.sol";

contract AcrossMessageHandlerMock is AcrossMessageHandler {
    function handleAcrossMessage(
        address tokenSent,
        uint256 amount,
        bool fillCompleted,
        address relayer,
        bytes memory message
    ) external override {}

    function handleUSSAcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
        bytes memory message
    ) external override {}
}
