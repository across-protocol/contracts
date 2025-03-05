// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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
 * @notice Facilitate bridging tokens via LayerZero's OFT.
 * @dev This contract is intended to be inherited by other chain-specific adapters and spoke pools.
 * @custom:security-contact bugs@across.to
 */
contract OFTTransportAdapter {
    using SafeERC20 for IERC20;
    using AddressToBytes32 for address;

    bytes public constant EMPTY_MSG_BYTES = new bytes(0);

    /**
     * @dev a fee cap we check against before sending a message with value to OFTMessenger as fees.
     * @dev this cap should be pretty conservative (high) to not interfere with operations under normal conditions.
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable FEE_CAP;

    /**
     * @notice The destination endpoint id in the OFT messaging protocol.
     * @dev Source https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts.
     * @dev Can also be found on target chain OFTAdapter -> endpoint() -> eid().
     */
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable DST_EID;

    /**
     * @notice intiailizes the OFTTransportAdapter contract.
     * @param _oftDstEid the endpoint ID that OFT protocol will transfer funds to.
     * @param _feeCap a fee cap we check against before sending a message with value to OFTMessenger as fees.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint32 _oftDstEid, uint256 _feeCap) {
        DST_EID = _oftDstEid;
        FEE_CAP = _feeCap;
    }

    /**
     * @notice transfer token to the other dstEId (e.g. chain) via OFT messaging protocol
     * @dev the caller has to provide both _token and _messenger. The caller is responsible for knowing the correct _messenger
     * @param _token token we're sending on current chain.
     * @param _messenger corresponding OFT messenger on current chain.
     * @param _to address to receive a trasnfer on the destination chain.
     * @param _amount amount to send.
     */
    function _transferViaOFT(
        IERC20 _token,
        IOFT _messenger,
        address _to,
        uint256 _amount
    ) internal {
        bytes32 to = _to.toBytes32();

        SendParam memory sendParam = SendParam(
            DST_EID,
            to,
            /**
             * _amount, _amount here specify `amountLD` and `minAmountLD`. These 2 have a subtle relationship
             * OFT "removes dust" on .send, which doesn't affect tokens like `USDT` because `USDT.decimals() = USDT_IOFT.sharedDecimals()`.
             * However, for other tokens we need to make sure that we're passing the correct `amount` to this function.
             * In order for OFT to remove zero dust, we need to make sure that last `token.decimals() - token_IOFT.sharedDecimals()` digits
             * in our amount are set to 0.
             * That said, setting both these vars to `_amount` protects us from dust subtraction on `OFT` contract side, which will revert
             * if we pass amount with some dust. It's important for our HubPool accounting to keep this behavior, meaning have
             * `sentAmount == receivedAmount` always
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
        MessagingFee memory fee = _messenger.quoteSend(sendParam, false);
        require(fee.nativeFee <= FEE_CAP, "OFT FEE_CAP exceeded");
        require(fee.nativeFee <= address(this).balance, "OFT insufficient funds for fee");

        // approve the exact _amount for `_messenger` to spend. Fee will be paid in native token
        _token.forceApprove(address(_messenger), _amount);

        (, OFTReceipt memory oftReceipt) = _messenger.send{ value: fee.nativeFee }(sendParam, fee, address(this));

        // we require that received amount of this transfer at destination exactly matches the sent amount
        require(_amount == oftReceipt.amountReceivedLD, "OFT incorrect amountReceivedLD");
    }
}
