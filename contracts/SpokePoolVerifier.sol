// SPDX-License-Identifier: BUSL-1.1
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

    /**
     * @notice Passthrough function to `deposit()` on the SpokePool contract.
     * @dev Protects the caller from losing their ETH (or other native token) by reverting if the SpokePool address
     * they intended to call does not exist on this chain. Because this contract can be deployed at the same address
     * everywhere callers should be protected even if the transaction is submitted to an unintended network.
     * This contract should only be used for native token deposits, as this problem only exists for native tokens.
     * @param spokePool Address of the SpokePool contract that the user is intending to call.
     * @param recipient Address to receive funds at on destination chain.
     * @param originToken Token to lock into this contract to initiate deposit.
     * @param amount Amount of tokens to deposit. Will be amount of tokens to receive less fees.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param relayerFeePct % of deposit amount taken out to incentivize a fast relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param maxCount used to protect the depositor from frontrunning to guarantee their quote remains valid.
     */
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
