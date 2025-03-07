// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/CCTPInterfaces.sol";
import "./CircleCCTPAdapter.sol";

/**
 * @notice Facilitate bridging USDC via Circle's CCTP V2 interface.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
abstract contract CircleCCTPV2Adapter is CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice The official Circle CCTP token bridge contract endpoint.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/evm-smart-contracts
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ITokenMessengerV2 public immutable cctpV2TokenMessenger;

    /**
     * @notice intiailizes the CircleCCTPAdapter contract.
     * @param _usdcToken USDC address on the current chain.
     * @param _cctpTokenMessenger V2 TokenMessenger contract to bridge via CCTP. If the zero address is passed, CCTP bridging will be disabled.
     * @param _recipientCircleDomainId The domain ID that CCTP will transfer funds to.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IERC20 _usdcToken,
        ITokenMessengerV2 _cctpTokenMessenger,
        uint32 _recipientCircleDomainId
    )
        CircleCCTPAdapter(
            _usdcToken,
            ITokenMessenger(address(0)), // Set the V1 TokenMessenger to the zero address to disable it
            _recipientCircleDomainId
        )
    {
        cctpV2TokenMessenger = _cctpTokenMessenger;
    }

    /**
     * @notice Returns whether or not the CCTP bridge is enabled.
     * @dev If the CCTPTokenMessenger is the zero address, CCTP bridging is disabled.
     */
    function _isCCTPEnabled() internal view virtual override returns (bool) {
        return address(cctpV2TokenMessenger) != address(0);
    }

    /**
     * @notice Transfers USDC from the current domain to the given address on the new domain. Uses the CCTP V2 "standard transfer" speed and
     * therefore pays no additional fee for the transfer to be sped up.
     * @dev This function will revert if the CCTP bridge is disabled. I.e. if the zero address is passed to the constructor for the cctpTokenMessenger.
     * @param to Address to receive USDC on the new domain represented as bytes32.
     * @param amount Amount of USDC to transfer.
     */
    function _transferUsdc(bytes32 to, uint256 amount) internal virtual override {
        // Only approve the exact amount to be transferred
        usdcToken.safeIncreaseAllowance(address(cctpV2TokenMessenger), amount);
        // Submit the amount to be transferred to bridged via the TokenMessenger.
        // If the amount to send exceeds the burn limit per message, then split the message into smaller parts.
        ITokenMinter cctpMinter = cctpV2TokenMessenger.localMinter();
        uint256 burnLimit = cctpMinter.burnLimitsPerMessage(address(usdcToken));
        uint256 remainingAmount = amount;
        while (remainingAmount > 0) {
            uint256 partAmount = remainingAmount > burnLimit ? burnLimit : remainingAmount;
            cctpV2TokenMessenger.depositForBurn(
                partAmount,
                recipientCircleDomainId,
                to,
                address(usdcToken),
                // The following parameters are new in this function from V2 to V1, can read more here:
                // https://developers.circle.com/stablecoins/evm-smart-contracts
                bytes32(0), // destinationCaller is set to bytes32(0) to indicate that anyone can call
                // receiveMessage on the destination to finalize the transfer
                0, // maxFee can be set to 0 for a "standard transfer"
                2000 // minFinalityThreshold can be set to 20000 for a "standard transfer",
                // https://github.com/circlefin/evm-cctp-contracts/blob/63ab1f0ac06ce0793c0bbfbb8d09816bc211386d/src/v2/FinalityThresholds.sol#L21
            );
            remainingAmount -= partAmount;
        }
    }
}
