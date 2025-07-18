// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/CCTPInterfaces.sol";
import { AddressToBytes32 } from "../libraries/AddressConverters.sol";

library CircleDomainIds {
    uint32 public constant Ethereum = 0;
    uint32 public constant Optimism = 2;
    uint32 public constant Arbitrum = 3;
    uint32 public constant Solana = 5;
    uint32 public constant Base = 6;
    uint32 public constant Polygon = 7;
    uint32 public constant DoctorWho = 10;
    uint32 public constant Linea = 11;
    uint32 public constant UNINITIALIZED = type(uint32).max;
}

/**
 * @notice Facilitate bridging USDC via Circle's CCTP.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
abstract contract CircleCCTPAdapter {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;
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
     * @notice Indicates if the CCTP V2 TokenMessenger is being used.
     * @dev This is determined by checking if the feeRecipient() function exists and returns a non-zero address.
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    bool public immutable cctpV2;

    /**
     * @notice intiailizes the CircleCCTPAdapter contract.
     * @param _usdcToken USDC address on the current chain.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP. If the zero address is passed, CCTP bridging will be disabled.
     * @param _recipientCircleDomainId The domain ID that CCTP will transfer funds to.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IERC20 _usdcToken,
        /// @dev This should ideally be an address but it's kept as an ITokenMessenger to avoid rippling changes to the
        /// constructors for every SpokePool/Adapter.
        ITokenMessenger _cctpTokenMessenger,
        uint32 _recipientCircleDomainId
    ) {
        usdcToken = _usdcToken;
        cctpTokenMessenger = _cctpTokenMessenger;
        recipientCircleDomainId = _recipientCircleDomainId;

        // Only the CCTP V2 TokenMessenger has a feeRecipient() function, so we use it to
        // figure out if we are using CCTP V2 or V1. `success` can be true even if the contract doesn't
        // implement feeRecipient but it has a fallback function so to be extra safe, we check the return value
        // of feeRecipient() as well.
        (bool success, bytes memory feeRecipient) = address(cctpTokenMessenger).staticcall(
            abi.encodeWithSignature("feeRecipient()")
        );
        // In case of a call to nonexistent contract or a call to a contract with a fallback function which
        // doesn't return any data, feeRecipient can be empty so check its length.
        // Even with this check, it's possible that the contract has implemented a fallback function that returns
        // 32 bytes of data but its not actually the feeRecipient address. This is extremely low risk but worth
        // mentioning that the following check is not 100% safe.
        cctpV2 = (success &&
            feeRecipient.length == 32 &&
            address(uint160(uint256(bytes32(feeRecipient)))) != address(0));
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
        _transferUsdc(to.toBytes32(), amount);
    }

    /**
     * @notice Transfers USDC from the current domain to the given address on the new domain.
     * @dev This function will revert if the CCTP bridge is disabled. I.e. if the zero address is passed to the constructor for the cctpTokenMessenger.
     * @param to Address to receive USDC on the new domain represented as bytes32.
     * @param amount Amount of USDC to transfer.
     */
    function _transferUsdc(bytes32 to, uint256 amount) internal {
        // Only approve the exact amount to be transferred
        usdcToken.safeIncreaseAllowance(address(cctpTokenMessenger), amount);
        // Submit the amount to be transferred to bridge via the TokenMessenger.
        // If the amount to send exceeds the burn limit per message, then split the message into smaller parts.
        // @dev We do not care about casting cctpTokenMessenger to ITokenMessengerV2 since both V1 and V2
        // expose a localMinter() view function that returns either an ITokenMinterV1 or ITokenMinterV2. Regardless,
        // we only care about the burnLimitsPerMessage function which is available in both versions and performs
        // the same logic, therefore we purposefully do not re-cast the cctpTokenMessenger and cctpMinter
        // to the specific version.
        ITokenMinter cctpMinter = cctpTokenMessenger.localMinter();
        uint256 burnLimit = cctpMinter.burnLimitsPerMessage(address(usdcToken));
        uint256 remainingAmount = amount;
        while (remainingAmount > 0) {
            uint256 partAmount = remainingAmount > burnLimit ? burnLimit : remainingAmount;
            if (cctpV2) {
                // Uses the CCTP V2 "standard transfer" speed and
                // therefore pays no additional fee for the transfer to be sped up.
                ITokenMessengerV2(address(cctpTokenMessenger)).depositForBurn(
                    partAmount,
                    recipientCircleDomainId,
                    to,
                    address(usdcToken),
                    // The following parameters are new in this function from V2 to V1, can read more here:
                    // https://developers.circle.com/stablecoins/evm-smart-contracts
                    bytes32(0), // destinationCaller is set to bytes32(0) to indicate that anyone can call
                    // receiveMessage on the destination to finalize the transfer
                    0, // maxFee can be set to 0 for a "standard transfer"
                    2000 // minFinalityThreshold can be set to 2000 for a "standard transfer",
                    // https://github.com/circlefin/evm-cctp-contracts/blob/63ab1f0ac06ce0793c0bbfbb8d09816bc211386d/src/v2/FinalityThresholds.sol#L21
                );
            } else {
                cctpTokenMessenger.depositForBurn(partAmount, recipientCircleDomainId, to, address(usdcToken));
            }
            remainingAmount -= partAmount;
        }
    }
}
