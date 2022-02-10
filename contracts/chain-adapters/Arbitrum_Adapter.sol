// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";
import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "arb-bridge-eth/contracts/bridge/interfaces/IInbox.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Arbitrum_Adapter is Base_Adapter {
    // Gas limit for immediate L2 execution attempt (can be estimated via NodeInterface.estimateRetryableTicket).
    // NodeInterface precompile interface exists at L2 address 0x00000000000000000000000000000000000000C8
    uint32 public defaultGasLimit = 5_000_000;

    // Amount of ETH allocated to pay for the base submission fee. The base submission fee is a parameter unique to
    // retryable transactions; the user is charged the base submission fee to cover the storage costs of keeping their
    // ticket’s calldata in the retry buffer. (current base submission fee is queryable via
    // ArbRetryableTx.getSubmissionPrice). ArbRetryableTicket precompile interface exists at L2 address
    // 0x000000000000000000000000000000000000006E.
    uint256 public defaultMaxSubmissionCost = 0.1e18;

    // L2 Gas price bid for immediate L2 execution attempt (queryable via standard eth*gasPrice RPC)
    uint256 public defaultGasPrice = 10e9; // 10 gWei

    // This address on L2 receives extra ETH that is left over after relaying a message via the inbox.
    address public refundL2Address;

    IInbox l1Inbox;

    constructor(
        WETH9 _l1Weth,
        address _hubPool,
        address,
        IL1StandardBridge _l1StandardBridge
    ) Base_Adapter(_hubPool) {}

    function relayMessage(address target, bytes memory message) external payable override onlyHubPool {
        uint256 requiredL1CallValue = _getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");

        uint256 ticketID = l1Inbox.createRetryableTicket{ value: requiredL1CallValue }(
            target,
            0,
            defaultMaxSubmissionCost,
            refundL2Address,
            refundL2Address,
            defaultGasLimit,
            gasPriceBid,
            data
        );
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override onlyHubPool {}

    receive() external payable {
        //TODO
    }

    function _getL1CallValue() internal view returns (uint256) {
        // This could overflow if these values are set too high, but since they are configurable by trusted owner
        // we won't catch this case.
        return defaultMaxSubmissionCost + defaultGasPrice * defaultGasLimit;
    }
}
