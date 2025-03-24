// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AddressToBytes32 } from "../libraries/AddressConverters.sol";
import { IHypXERC20Router } from "../interfaces/IHypXERC20Router.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Facilitate bridging tokens via Hyperlane's XERC20.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
contract HypXERC20Adapter {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;

    /**
     * @dev a fee cap we check against before sending a message with value to Hyperlane as fees.
     * @dev this cap should be pretty conservative (high) to not interfere with operations under normal conditions.
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable HYP_FEE_CAP;

    /**
     * @notice The destination domain id in the Hyperlane messaging protocol.
     * @dev source https://github.com/hyperlane-xyz/hyperlane-registry
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable HYP_DST_DOMAIN;

    error HypFeeCapExceeded();
    error HypInsufficientBalanceForFee();

    /**
     * @notice initializes the HyperlaneXERC20Adapter contract.
     * @param _dstDomainId the domain ID that Hyperlane protocol will transfer funds to.
     * @param _feeCap a fee cap we check against before sending a message with value to Hyperlane as fees.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint32 _dstDomainId, uint256 _feeCap) {
        HYP_DST_DOMAIN = _dstDomainId;
        HYP_FEE_CAP = _feeCap;
    }

    /**
     * @notice transfer token to the other destination domain (e.g. chain) via Hyperlane messaging protocol
     * @dev the caller has to provide both _token and _router. The caller is responsible for knowing the correct _router
     * @param _token token we're sending on current chain.
     * @param _router corresponding XERC20 router on current chain.
     * @param _to address to receive a transfer on the destination chain.
     * @param _amount amount to send.
     */
    function _transferXERC20ViaHyperlane(
        IERC20 _token,
        IHypXERC20Router _router,
        address _to,
        uint256 _amount
    ) internal {
        bytes32 to = _to.toBytes32();

        // Quote the gas payment required for the transfer
        uint256 fee = _router.quoteGasPayment(HYP_DST_DOMAIN);
        if (fee > HYP_FEE_CAP) revert HypFeeCapExceeded();
        if (fee > address(this).balance) revert HypInsufficientBalanceForFee();

        // Approve the exact _amount for `_router` to spend
        _token.forceApprove(address(_router), _amount);

        // Send the transfer via Hyperlane. Return value is not useful to check
        _router.transferRemote{ value: fee }(HYP_DST_DOMAIN, to, _amount);
    }
}
