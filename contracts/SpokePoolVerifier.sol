// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/SpokePoolInterface.sol";

/**
 * @notice SpokePoolVerifier is a contract that verifies that the SpokePool exists on this chain before sending ETH to it.
 * @dev This contract must be deployed via Create2 to the same address on all chains. That way, an errant transaction sent
 * to the wrong chain will be blocked by this contract rather than hitting a dead address. This means that this contract
 * will not work to protect chains, like zkSync, where Create2 address derivations don't match other chains.
 * Source: https://era.zksync.io/docs/reference/architecture/differences-with-ethereum.html#create-create2
 */
contract SpokePoolVerifier {
    using Address for address;

    function deposit(
        SpokePoolInterface spokePool,
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 maxCount
    ) external payable {
        require(msg.value == amount, "msg.value != amount");
        require(address(spokePool).isContract(), "spokePool is not a contract");
        spokePool.deposit{ value: msg.value }(
            recipient,
            originToken,
            amount,
            destinationChainId,
            relayerFeePct,
            quoteTimestamp,
            message,
            maxCount
        );
    }
}
