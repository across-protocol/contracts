// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/CCTPInterfaces.sol";

library CircleDomainIds {
    uint32 public constant Ethereum = 0;
    uint32 public constant Optimism = 2;
    uint32 public constant Arbitrum = 3;
    uint32 public constant Base = 6;
    uint32 public constant Polygon = 7;
}

abstract contract CircleCCTPAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice The domain ID that CCTP will transfer funds to.
     * @dev This identifier is assigned by Circle and is not related to a chain ID.
     * @dev Official domain list can be found here: https://developers.circle.com/stablecoins/docs/supported-domains
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable recipientCircleDomainId;

    /**
     * @notice The official USDC contract address on this chain.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/usdc-on-main-networks
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IERC20 public immutable usdcToken;

    /**
     * @notice The official Circle CCTP token bridge contract endpoint.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/evm-smart-contracts
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ITokenMessenger public immutable cctpTokenMessenger;

    /**
     * @notice intiailizes the CircleCCTPAdapter contract.
     * @param _usdcToken USDC address on the current chain.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP. If the zero address is passed, CCTP bridging will be disabled.
     * @param _recipientCircleDomainId The domain ID that CCTP will transfer funds to.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IERC20 _usdcToken,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _recipientCircleDomainId
    ) {
        usdcToken = _usdcToken;
        cctpTokenMessenger = _cctpTokenMessenger;
        recipientCircleDomainId = _recipientCircleDomainId;
    }

    /**
     * @notice converts address to bytes32 (alignment preserving cast.)
     * @param addr the address to convert to bytes32
     * @dev Sourced from the official CCTP repo: https://github.com/walkerq/evm-cctp-contracts/blob/139d8d0ce3b5531d3c7ec284f89d946dfb720016/src/messages/Message.sol#L142C1-L148C6
     */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Returns whether or not the CCTP bridge is enabled.
     * @dev If the CCTPTokenMessenger is the zero address, CCTP bridging is disabled.
     */
    function _isCCTPEnabled() internal view returns (bool) {
        return address(cctpTokenMessenger) != address(0);
    }

    /**
     * @notice Transfers USDC from the current domain to the given address on the new domain.
     * @dev This function will revert if the CCTP bridge is disabled. I.e. if the zero address is passed to the constructor for the cctpTokenMessenger.
     * @param to Address to receive USDC on the new domain.
     * @param amount Amount of USDC to transfer.
     */
    function _transferUsdc(address to, uint256 amount) internal {
        // Only approve the exact amount to be transferred
        usdcToken.safeIncreaseAllowance(address(cctpTokenMessenger), amount);
        // Submit the amount to be transferred to bridged via the TokenMessenger.
        // If the amount to send exceeds the burn limit per message, then split the message into smaller parts.
        ITokenMinter cctpMinter = cctpTokenMessenger.localMinter();
        uint256 burnLimit = cctpMinter.burnLimitsPerMessage(address(usdcToken));
        if (amount <= burnLimit) {
            cctpTokenMessenger.depositForBurn(
                amount,
                recipientCircleDomainId,
                _addressToBytes32(to),
                address(usdcToken)
            );
        } else {
            uint256 remainingAmount = amount;
            while (remainingAmount > 0) {
                uint256 partAmount = remainingAmount > burnLimit ? burnLimit : remainingAmount;
                cctpTokenMessenger.depositForBurn(
                    partAmount,
                    recipientCircleDomainId,
                    _addressToBytes32(to),
                    address(usdcToken)
                );
                remainingAmount -= partAmount;
            }
        }
    }
}
