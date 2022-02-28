// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "../interfaces/WETH9.sol";

import "@uma/core/contracts/common/implementation/Lockable.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Ethereum SpokePool.
 * @notice This contract should always be deployed on the same chain as the HubPool, as it acts as a pass-through
 * contract between HubPool and SpokePool on the same chain. Its named "Ethereum_Adapter" because a core assumption
 * is that the HubPool will be deployed on Ethereum, so this adapter will be used to communicate between HubPool
 * and the Ethereum_SpokePool.
 */
contract Ethereum_Adapter is AdapterInterface {
    using SafeERC20 for IERC20;

    /**
     * @notice Send message to target on Ethereum.
     * @notice This function, and contract overall, is not useful in practice except that the HubPool
     * expects to interact with the SpokePool via an Adapter, so when communicating to the Ethereum_SpokePool, it must
     * send messages via this pass-through contract.
     * @param target Contract that will receive message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        _executeCall(target, message);
        emit MessageRelayed(target, message);
    }

    /**
     * @notice Send tokens to target.
     * @param l1Token L1 token to send.
     * @param l2Token Unused parameter in this contract.
     * @param amount Amount of L1 tokens to send.
     * @param to recipient.
     */
    function relayTokens(
        address l1Token,
        address l2Token, // l2Token is unused for ethereum since we are assuming that the HubPool is only deployed
        // on this network.
        uint256 amount,
        address to
    ) external payable override {
        IERC20(l1Token).safeTransfer(to, amount);
        emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    // Note: this snippet of code is copied from Governor.sol.
    function _executeCall(address to, bytes memory data) private {
        // Note: this snippet of code is copied from Governor.sol and modified to not include any "value" field.
        // solhint-disable-next-line no-inline-assembly

        bool success;
        assembly {
            let inputData := add(data, 0x20)
            let inputDataSize := mload(data)
            // Hardcode value to be 0 for relayed governance calls in order to avoid addressing complexity of bridging
            // value cross-chain.
            success := call(gas(), to, 0, inputData, inputDataSize, 0, 0)
        }
        require(success, "execute call failed");
    }
}
