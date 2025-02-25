// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IOFT, SendParam, OFTReceipt, MessagingReceipt, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
// import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol"; // todo: commented for now, potentially used in the code below, see todo comments

import { AddressToBytes32 } from "../libraries/AddressConverters.sol";

// todo: why does `IERC20` not provide `decimals` fn?
interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

// @note: this contract is built for a 1-to-1 relationship with `usdt` for now
// however, in theory, OFT can support any token. We can think about it when we
// need to support more OFT tokens
contract OFTTransportAdapter {
    using AddressToBytes32 for address;

    IERC20 public immutable usdt;
    IOFT public immutable oftTransport;

    // todo: make sure that this can't change under us
    // todo: can this somehow be queriable from the contract on our own chain if it ever changes?
    uint32 public immutable dstEid; // destination endpoint id in the OFT messaging protocol
    // todo ihor: arbitrum one is 30101. It should be found through `OFTAdapter -> endpoint() -> eid()` on the destination chain

    // todo: has to already contain the receiving domain's smth like(oft address + chain id)
    constructor(IERC20 _usdt, IOFT _oftTransport, uint32 _dstEid) {
        usdt = _usdt;
        // @dev: this contract assumes this decimal parity later in amount calculation.
        // todo ihor: well, in `_transferUsdt`, if we set `amountLD == minAmountLD`,
        // todo ihor: `oftTransport` should protect us from any rounding that happens due to decimals anyway. So perhaps this check can be removed
        require(IERC20Decimals(address(_usdt)).decimals() == _oftTransport.sharedDecimals(), "decimals don't match"); // todo: ugh, this is ugly and perhaps not required
        oftTransport = _oftTransport;
        dstEid = _dstEid;
    }

    // todo: seems cleaner if this contract decides the full oft branch in the adapter
    // e.g. if (_isOFTEnabled(token)) { ... }, rahter than adding extra token conditions in
    // the adapter itself
    /**
     * @notice Returns whether or not the OFT bridge is enabled.
     * @dev If the IOFT is the zero address, OFT bridging is disabled.
     */
    function _isOFTEnabled(address _token) internal view returns (bool) {
        // we have to have a oftTransport set and the token has to be USDT
        return address(oftTransport) != address(0) && address(usdt) == _token;
    }

    function _transferUsdt(address _to, uint256 amount) internal {
        // @dev: building `SendParam` struct
        // receiver address converted to bytes32
        bytes32 to = _to.toBytes32();

        // `amountLD` and `minAmountLD` have a subtle relationship
        // `minAmountLD` is used to check against when "the dust"
        // is removed from `amountLD`. `amountLD` will be the sent amount for tokens with 6 decimals
        // For tokens with other decimal params, please look at `_debitView` function in `OFTCore.sol`
        // For usdt with 6 decimals, `amountLD == minAmountLD` should never fail
        uint256 amountLD = amount;
        uint256 minAmountLD = amount;

        // empty options with version identifier. In current version, looks like `0x0003`
        // todo: as per TG chat, can set this to empty bytes instead and should be fine
        // bytes memory extraOptions = OptionsBuilder.newOptions(); // todo: this requires installing an extra lib `solidity-bytes-utils`
        bytes memory extraOptions = new bytes(0);

        // todo: can make these an immutable storage var, ZERO_BYTES? Idk
        bytes memory composeMsg = new bytes(0);
        bytes memory oftCmd = new bytes(0);

        SendParam memory sendParam = SendParam(dstEid, to, amountLD, minAmountLD, extraOptions, composeMsg, oftCmd);

        MessagingFee memory fee = oftTransport.quoteSend(sendParam, false);

        // @dev setting refundAddress to zero addr here, because we calculate the fees precicely and we can save gas this way
        // todo: not really sure if we should blindly trust the fee.nativeFee here and just send it away. Should we check it against some sane cap?
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) = oftTransport.send{ value: fee.nativeFee }(
            sendParam,
            fee,
            address(0)
        );

        // todo: possible further actions:
        // 1.
        // require(amount == oftReceipt.amountSentLD);
        // require(amount == oftReceipt.amountReceivedLD);
        // 2.
        // emit some event, but OFTAdapter already does emit `event OFTSent`, so probably no
    }
}
