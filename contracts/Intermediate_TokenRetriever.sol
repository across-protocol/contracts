// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import "./Lockable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

interface IBridgeAdapter {
    function withdrawToken(
        address recipient,
        uint256 amountToReturn,
        address l2Token
    ) external;
}

/**
 * @notice Contract deployed on an arbitrary L2 to act as an intermediate contract for withdrawals from L3 to L1.
 * @dev Since each network has its own bridging requirements, this contract delegates that logic to a bridge adapter contract
 * which performs the necessary withdraw action.
 */
contract Intermediate_TokenRetriever is Lockable, MultiCaller {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // Should be set to the bridge adapter which contains the proper logic to withdraw tokens on
    // the deployed L2
    address public immutable bridgeAdapter;
    // Should be set to the L1 address which will receive withdrawn tokens.
    address public immutable tokenRetriever;

    error WithdrawalFailed(address l2Token);

    /**
     * @notice Constructs the Intermediate_TokenRetriever
     * @param _bridgeAdapter contract which contains network's bridging logic.
     * @param _tokenRetriever L1 address of the recipient of withdrawn tokens.
     */
    constructor(address _bridgeAdapter, address _tokenRetriever) {
        //slither-disable-next-line missing-zero-check
        bridgeAdapter = _bridgeAdapter;
        tokenRetriever = _tokenRetriever;
    }

    /**
     * @notice delegatecalls the contract's stored bridge adapter to bridge tokens back to the defined token retriever
     * @notice This follows the bridging logic of the corresponding bridge adapter.
     * @param l2Token (current network's) contract address of the token to be withdrawn.
     */
    function retrieve(address l2Token) public nonReentrant {
        (bool success, ) = bridgeAdapter.delegatecall(
            abi.encodeCall(
                IBridgeAdapter.withdrawToken,
                (tokenRetriever, IERC20Upgradeable(l2Token).balanceOf(address(this)), l2Token)
            )
        );
        if (!success) revert WithdrawalFailed(l2Token);
    }
}
