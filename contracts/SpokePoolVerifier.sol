// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "./interfaces/V3SpokePoolInterface.sol";

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
     * @param inputToken Token to lock into this contract to initiate deposit.
     * @param outputToken Token to receive on destination chain.
     * @param inputAmount Amount of tokens to deposit.
     * @param outputAmount Amount of tokens to receive on destination chain.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param exclusiveRelayer Address of relayer who can fill this deposit before exclusivityDeadline.
     * @param fillDeadline Timestamp after which this deposit can no longer be filled.
     * @param quoteTimestamp Timestamp used by Across to compute this deposit's fee based on HubPool state. This is
     * passed in because this contract is unaware of current timestamp on HubPool chain (i.e. Ethereum).
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     */
    function deposit(
        V3SpokePoolInterface spokePool,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable {
        require(msg.value == inputAmount, "msg.value != amount");
        require(address(spokePool).isContract(), "spokePool is not a contract");
        // Set msg.sender as the depositor so that msg.sender can speed up the deposit.
        spokePool.depositV3{ value: msg.value }(
            msg.sender,
            recipient,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            message
        );
    }
}
