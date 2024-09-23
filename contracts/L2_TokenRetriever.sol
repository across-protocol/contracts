// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import { Lockable } from "./Lockable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { SafeERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import { WithdrawalAdapter } from "./chain-adapters/l2/WithdrawalAdapter.sol";

interface IBridgeAdapter {
    function withdrawTokens(WithdrawalAdapter.WithdrawalInformation[] memory) external;
}

/**
 * @notice Contract deployed on an arbitrary L2 to act as an intermediate contract for withdrawals from L3 to L1.
 * @dev Since each network has its own bridging requirements, this contract delegates that logic to a bridge adapter contract
 * which performs the necessary withdraw action.
 */
contract L2_TokenRetriever is Lockable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Should be set to the bridge adapter which contains the proper logic to withdraw tokens on
    // the deployed L2
    address public immutable bridgeAdapter;
    // Should be set to the L1 address which will receive withdrawn tokens.
    address public immutable tokenRecipient;

    error RetrieveFailed(address[] l2Tokens);

    /**
     * @notice Constructs the L2_TokenRetriever
     * @param _bridgeAdapter contract which contains network's bridging logic.
     * @param _tokenRecipient L1 address of the recipient of withdrawn tokens.
     */
    constructor(address _bridgeAdapter, address _tokenRecipient) {
        bridgeAdapter = _bridgeAdapter;
        tokenRecipient = _tokenRecipient;
    }

    /**
     * @notice delegatecalls the bridge adapter to withdraw multiple different L2 tokens.
     * @dev this is preferrable to multicalling `retrieve` since instead of `n` delegatecalls for `n`
     * withdrawal txns, we can have 1 delegatecall for `n` withdrawal transactions.
     * @param l2Tokens (current network's) contracts addresses of the l2 tokens to be withdrawn.
     */
    function retrieve(address[] memory l2Tokens) external nonReentrant {
        uint256 nWithdrawals = l2Tokens.length;
        WithdrawalAdapter.WithdrawalInformation[] memory withdrawals = new WithdrawalAdapter.WithdrawalInformation[](
            nWithdrawals
        );
        for (uint256 i = 0; i < nWithdrawals; ++i) {
            address l2Token = l2Tokens[i];
            withdrawals[i] = WithdrawalAdapter.WithdrawalInformation(
                tokenRecipient,
                l2Token,
                IERC20Upgradeable(l2Token).balanceOf(address(this))
            );
        }
        (bool success, ) = bridgeAdapter.delegatecall(abi.encodeCall(IBridgeAdapter.withdrawTokens, (withdrawals)));
        if (!success) revert RetrieveFailed(l2Tokens);
    }
}
