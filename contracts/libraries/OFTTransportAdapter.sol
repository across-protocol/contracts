// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { AddressToBytes32 } from "../libraries/AddressConverters.sol";

/**
 * @notice List of OFT endpoint ids for different chains.
 * @dev source https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts.
 */
library OFTEIds {
    uint32 public constant Ethereum = 30101;
    uint32 public constant Arbitrum = 30110;
    // Use this value for placeholder purposes only for adapters that extend this adapter but haven't yet been
    // assigned a domain ID by OFT messaging protocol.
    uint32 public constant UNINITIALIZED = type(uint32).max;
}

/**
 * @notice Facilitate bridging USDT via LayerZero's OFT.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools. This contract is built for 1-to-1 relationship with USDT to facilitate USDT0. When adding other contracts, we'd need to add a token mapping instead of the immutable token address.
 * @custom:security-contact bugs@across.to
 */
contract OFTTransportAdapter {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;

    bytes public constant EMPTY_MSG_BYTES = new bytes(0);
    address public constant ZERO_ADDRESS = address(0);

    // USDT address on current chain.
    IERC20 public immutable USDT;
    // Mailbox address for OFT cross-chain transfers.
    IOFT public immutable OFT_MESSENGER;

    /**
     * @notice The destination endpoint id in the OFT messaging protocol.
     * @dev Source https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts.
     * @dev Can also be found on target chain OFTAdapter -> endpoint() -> eid().
     */
    uint32 public immutable DST_EID;

    /**
     * @notice intiailizes the OFTTransportAdapter contract.
     * @param _usdt USDT address on the current chain.
     * @param _oftMessenger OFTAdapter contract to bridge to the other chain. If address is set to zero, OFT bridging will be disabled.
     * @param _oftDstEid The endpoint ID that OFT will transfer funds to.
     */
    constructor(
        IERC20 _usdt,
        IOFT _oftMessenger,
        uint32 _oftDstEid
    ) {
        USDT = _usdt;
        OFT_MESSENGER = _oftMessenger;
        DST_EID = _oftDstEid;
    }

    /**
     * @notice Returns whether or not the OFT bridge is enabled.
     * @dev If the IOFT is the zero address, OFT bridging is disabled.
     */
    function _isOFTEnabled(address _token) internal view returns (bool) {
        return address(OFT_MESSENGER) != address(0) && address(USDT) == _token;
    }

    /**
     * @notice transfers usdt to destination endpoint
     * @param _to address to receive a trasnfer on the destination chain
     * @param _amount amount to send
     */
    function _transferUsdt(address _to, uint256 _amount) internal {
        bytes32 to = _to.toBytes32();

        SendParam memory sendParam = SendParam(
            DST_EID,
            to,
            /**
             * _amount, _amount here specify `amountLD` and `minAmountLD`. These 2 have a subtle relationship
             * OFT "removes dust" on .send, which should not affect USDT transfer because of how OFT works internally with 6-decimal tokens.
             * Setting them both to `_amount` protects us from dust subtraction on the OFT side. If any dust is subtracted, the later .send should revert.
             */
            _amount,
            _amount,
            /**
             * EMPTY_MSG_BYTES, EMPTY_MSG_BYTES, EMPTY_MSG_BYTES here specify `extraOptions`, `composeMsg` and `oftCmd`.
             * These can be set to empty bytes arrays for the purposes of sending a simple cross-chain transfer.
             */
            EMPTY_MSG_BYTES,
            EMPTY_MSG_BYTES,
            EMPTY_MSG_BYTES
        );

        // `false` in the 2nd param here refers to `bool _payInLzToken`. We will pay in native token, so set to `false`
        MessagingFee memory fee = OFT_MESSENGER.quoteSend(sendParam, false);

        // approve the exact _amount for `OFT_MESSENGER` to spend. Fee will be paid in native token
        USDT.forceApprove(address(OFT_MESSENGER), _amount);

        // todo: not really sure if we should blindly trust the fee.nativeFee here and just send it away. Should we check it against some sane cap?
        // setting `refundAddress` to `ZERO_ADDRESS` here, because we calculate the fees precicely and we can save gas this way
        (, OFTReceipt memory oftReceipt) = OFT_MESSENGER.send{ value: fee.nativeFee }(sendParam, fee, ZERO_ADDRESS);

        // we require that received amount of this transfer at destination exactly matches the sent amount
        require(_amount == oftReceipt.amountReceivedLD, "incorrect amountReceivedLD");
    }
}
