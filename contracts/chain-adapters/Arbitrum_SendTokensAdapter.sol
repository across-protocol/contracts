// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";
import "./Arbitrum_Adapter.sol"; // Used to import `ArbitrumL1ERC20GatewayLike`

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice This adapter is built for emergencies to send funds from the Hub to a Spoke in the event that a spoke pool
 * received a duplicate root bundle relay, due to some replay issue.
 */
// solhint-disable-next-line contract-name-camelcase
contract Arbitrum_SendTokensAdapter is AdapterInterface {
    using SafeERC20 for IERC20;

    uint256 public immutable l2MaxSubmissionCost = 0.01e18;
    uint256 public immutable l2GasPrice = 5e9;
    uint32 public immutable l2GasLimit = 2_000_000;

    ArbitrumL1ERC20GatewayLike public immutable l1ERC20GatewayRouter;

    /**
     * @notice Constructs new Adapter.
     * @param _l1ERC20GatewayRouter ERC20 gateway router contract to send tokens to Arbitrum.
     */
    constructor(ArbitrumL1ERC20GatewayLike _l1ERC20GatewayRouter) {
        l1ERC20GatewayRouter = _l1ERC20GatewayRouter;
    }

    /**
     * @notice Send tokens to SpokePool. Enables HubPool admin to call relaySpokePoolAdminFunction that will trigger
     * this function.
     * @dev This performs similar logic to relayTokens in the normal Arbitrum_Adapter by sending tokens
     * the Arbitrum_SpokePool out of the HubPool.
     * @param message The encoded address of the ERC20 to send to the rescue address.
     */
    function relayMessage(address target, bytes memory message) external payable override {
        (address l1Token, uint256 amount) = abi.decode(message, (address, uint256));

        uint256 requiredL1CallValue = _contractHasSufficientEthBalance();

        // Approve the gateway, not the router, to spend the hub pool's balance. The gateway, which is different
        // per L1 token, will temporarily escrow the tokens to be bridged and pull them from this contract.
        address erc20Gateway = l1ERC20GatewayRouter.getGateway(l1Token);
        IERC20(l1Token).safeIncreaseAllowance(erc20Gateway, amount);

        // `outboundTransfer` expects that the caller includes a bytes message as the last param that includes the
        // maxSubmissionCost to use when creating an L2 retryable ticket: https://github.com/OffchainLabs/arbitrum/blob/e98d14873dd77513b569771f47b5e05b72402c5e/packages/arb-bridge-peripherals/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol#L232
        bytes memory data = abi.encode(l2MaxSubmissionCost, "");

        // Note: outboundTransfer() will ultimately create a retryable ticket and set this contract's address as the
        // refund address. This means that the excess ETH to pay for the L2 transaction will be sent to the aliased
        // contract address on L2 and lost.
        l1ERC20GatewayRouter.outboundTransfer{ value: requiredL1CallValue }(
            l1Token,
            target,
            amount,
            l2GasLimit,
            l2GasPrice,
            data
        );

        // Purposefully not emitting any events so as not to confuse off-chain monitors that track this event.
        // emit TokensRelayed(l1Token, l2Token, amount, to);
    }

    /**
     * @notice Should never be called.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        revert("relayTokens disabled");
    }

    /**
     * @notice Returns required amount of ETH to send a message via the Inbox.
     * @return amount of ETH that this contract needs to hold in order for relayMessage to succeed.
     */
    function getL1CallValue() public pure returns (uint256) {
        return l2MaxSubmissionCost + l2GasPrice * l2GasLimit;
    }

    function _contractHasSufficientEthBalance() internal view returns (uint256 requiredL1CallValue) {
        requiredL1CallValue = getL1CallValue();
        require(address(this).balance >= requiredL1CallValue, "Insufficient ETH balance");
    }
}
