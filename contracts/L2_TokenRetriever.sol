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

    struct TokenPair {
        address l1Token;
        address l2Token;
    }

    // Should be set to the bridge adapter which contains the proper logic to withdraw tokens on
    // the deployed L2
    address public immutable bridgeAdapter;
    // Should be set to the L1 address which will receive withdrawn tokens.
    address public immutable tokenRecipient;

    error RetrieveFailed();

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
     * @param tokenPairs l1 and l2 addresses of the token to withdraw.
     */
    function retrieve(TokenPair[] memory tokenPairs) external nonReentrant {
        uint256 nWithdrawals = tokenPairs.length;
        WithdrawalAdapter.WithdrawalInformation[] memory withdrawals = new WithdrawalAdapter.WithdrawalInformation[](
            nWithdrawals
        );
        TokenPair memory tokenPair;
        for (uint256 i = 0; i < nWithdrawals; ++i) {
            tokenPair = tokenPairs[i];
            withdrawals[i] = WithdrawalAdapter.WithdrawalInformation(
                tokenRecipient,
                tokenPair.l1Token,
                tokenPair.l2Token,
                IERC20Upgradeable(tokenPair.l2Token).balanceOf(address(this))
            );
        }
        (bool success, ) = bridgeAdapter.delegatecall(abi.encodeCall(IBridgeAdapter.withdrawTokens, (withdrawals)));
        if (!success) revert RetrieveFailed();
    }
}
