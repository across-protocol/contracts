// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Lockable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface USDYieldManager {
    function claimWithdrawal(uint256 _requestId, uint256 _hintId) external returns (bool success);
}

/**
 * @notice Contract deployed on Ethereum to facilitate DAI transfers from Blast to the HubPool.
 * @dev Blast USDB withdrawals are a two step process where the L2 to L1 withdrawal must first be finalized via
 * the typical OP Stack mechanism, and then a claim from the withdrawal's *recipient* must be made against a
 * USDBYieldManager contract. This means that the Blast_SpokePool must set its recipient to this contract's address
 * and then an EOA can call this contract to retrieve the DAI.
 */
contract Blast_DaiRetriever is Lockable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Should be set to HubPool on Ethereum
    address public immutable hubPool;

    // USDCYieldManager contract on Ethereum which releases DAI to the hubPool.
    USDYieldManager public immutable usdYieldManager;

    // Token to be retrieved.
    IERC20Upgradeable public immutable dai;

    /**
     * @notice Constructs USDB Retriever
     * @param _hubPool Where to send DAI to.
     * @param _usdYieldManager USDCYieldManager contract on Ethereum.
     * @param _dai DAI token to be retrieved.
     */
    constructor(
        address _hubPool,
        USDYieldManager _usdYieldManager,
        IERC20Upgradeable _dai
    ) {
        //slither-disable-next-line missing-zero-check
        hubPool = _hubPool;
        usdYieldManager = _usdYieldManager;
        dai = _dai;
    }

    /**
     * @notice Calls USDCYieldManager contract to release DAI and send to the hubPool. Required to use this function
     * to retrieve DAI since only the L2 withdrawal recipient can make this call.
     * @notice This can revert if the claim is not ready yet. It takes ~12 hours for a Blast admin to make the DAI
     * available for retrieval following withdrawal finalization.
     * @param _requestId L2 withdrawal request ID. Emitted in L1 WithdrawalRequested event when the L2 to L1
     * withdrawal is first "finalized" but still awaiting the recipient to claim the DAI.
     * @param _hintId Checkpoint hint ID. Can be found by querying USDYieldManager.findCheckpointHint.
     */
    function retrieve(uint256 _requestId, uint256 _hintId) public nonReentrant {
        require(usdYieldManager.claimWithdrawal(_requestId, _hintId), "claim failed");
        dai.safeTransfer(hubPool, dai.balanceOf(address(this)));
    }
}
