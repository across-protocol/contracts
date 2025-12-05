// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { PrecompileLib } from "./PrecompileLib.sol";
import { HLConstants } from "./common/HLConstants.sol";
import { HLConversions } from "./common/HLConversions.sol";

import { ICoreWriter } from "./interfaces/ICoreWriter.sol";

/**
 * @title CoreWriterLib v1.0
 * @author Obsidian (https://x.com/ObsidianAudits)
 * @notice A library for interacting with HyperEVM's CoreWriter
 *
 * @dev Additional functionality for:
 * - Bridging assets between EVM and HyperCore
 * - Converting decimal representations between EVM and HyperCore amounts
 * - Security checks before sending actions to CoreWriter
 */
library CoreWriterLib {
    using SafeERC20 for IERC20;

    ICoreWriter constant coreWriter = ICoreWriter(0x3333333333333333333333333333333333333333);

    error CoreWriterLib__StillLockedUntilTimestamp(uint64 lockedUntilTimestamp);
    error CoreWriterLib__CannotSelfTransfer();
    error CoreWriterLib__HypeTransferFailed();
    error CoreWriterLib__CoreAmountTooLarge(uint256 amount);
    error CoreWriterLib__EvmAmountTooSmall(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                       EVM <---> Core Bridging
    //////////////////////////////////////////////////////////////*/

    function bridgeToCore(address tokenAddress, uint256 evmAmount) internal {
        uint64 tokenIndex = PrecompileLib.getTokenIndex(tokenAddress);
        bridgeToCore(tokenIndex, evmAmount);
    }

    function bridgeToCore(uint64 token, uint256 evmAmount) internal {
        // Check if amount would be 0 after conversion to prevent token loss
        uint64 coreAmount = HLConversions.evmToWei(token, evmAmount);
        if (coreAmount == 0) revert CoreWriterLib__EvmAmountTooSmall(evmAmount);
        address systemAddress = getSystemAddress(token);
        if (isHype(token)) {
            (bool success, ) = systemAddress.call{ value: evmAmount }("");
            require(success, "HYPE transfer failed");
        } else {
            PrecompileLib.TokenInfo memory info = PrecompileLib.tokenInfo(uint32(token));
            address tokenAddress = info.evmContract;
            IERC20(tokenAddress).safeTransfer(systemAddress, evmAmount);
        }
    }

    function bridgeToEvm(address tokenAddress, uint256 evmAmount) internal {
        uint64 tokenIndex = PrecompileLib.getTokenIndex(tokenAddress);
        bridgeToEvm(tokenIndex, evmAmount, true);
    }

    // NOTE: For bridging non-HYPE tokens, the contract must hold some HYPE on core (enough to cover the transfer gas), otherwise spotSend will fail
    function bridgeToEvm(uint64 token, uint256 amount, bool isEvmAmount) internal {
        address systemAddress = getSystemAddress(token);

        uint64 coreAmount;
        if (isEvmAmount) {
            coreAmount = HLConversions.evmToWei(token, amount);
            if (coreAmount == 0) revert CoreWriterLib__EvmAmountTooSmall(amount);
        } else {
            if (amount > type(uint64).max) revert CoreWriterLib__CoreAmountTooLarge(amount);
            coreAmount = uint64(amount);
        }

        spotSend(systemAddress, token, coreAmount);
    }

    function spotSend(address to, uint64 token, uint64 amountWei) internal {
        // Self-transfers will always fail, so reverting here
        require(to != address(this), "Cannot self-transfer");

        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.SPOT_SEND_ACTION, abi.encode(to, token, amountWei))
        );
    }

    /*//////////////////////////////////////////////////////////////
                          Bridging Utils
    //////////////////////////////////////////////////////////////*/

    function getSystemAddress(uint64 index) internal view returns (address) {
        if (index == HLConstants.hypeTokenIndex()) {
            return HLConstants.HYPE_SYSTEM_ADDRESS;
        }
        return address(HLConstants.BASE_SYSTEM_ADDRESS + index);
    }

    function isHype(uint64 index) internal view returns (bool) {
        return index == HLConstants.hypeTokenIndex();
    }

    /*//////////////////////////////////////////////////////////////
                              Staking
    //////////////////////////////////////////////////////////////*/
    function delegateToken(address validator, uint64 amountWei, bool undelegate) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.TOKEN_DELEGATE_ACTION, abi.encode(validator, amountWei, undelegate))
        );
    }

    function depositStake(uint64 amountWei) internal {
        coreWriter.sendRawAction(abi.encodePacked(uint8(1), HLConstants.STAKING_DEPOSIT_ACTION, abi.encode(amountWei)));
    }

    function withdrawStake(uint64 amountWei) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.STAKING_WITHDRAW_ACTION, abi.encode(amountWei))
        );
    }

    /*//////////////////////////////////////////////////////////////
                              Trading
    //////////////////////////////////////////////////////////////*/

    function toMilliseconds(uint64 timestamp) internal pure returns (uint64) {
        return timestamp * 1000;
    }

    function _canWithdrawFromVault(address vault) internal view returns (bool, uint64) {
        PrecompileLib.UserVaultEquity memory vaultEquity = PrecompileLib.userVaultEquity(address(this), vault);

        return (
            toMilliseconds(uint64(block.timestamp)) > vaultEquity.lockedUntilTimestamp,
            vaultEquity.lockedUntilTimestamp
        );
    }

    function vaultTransfer(address vault, bool isDeposit, uint64 usdAmount) internal {
        if (!isDeposit) {
            (bool canWithdraw, uint64 lockedUntilTimestamp) = _canWithdrawFromVault(vault);

            if (!canWithdraw) revert CoreWriterLib__StillLockedUntilTimestamp(lockedUntilTimestamp);
        }

        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.VAULT_TRANSFER_ACTION, abi.encode(vault, isDeposit, usdAmount))
        );
    }

    function transferUsdClass(uint64 ntl, bool toPerp) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.USD_CLASS_TRANSFER_ACTION, abi.encode(ntl, toPerp))
        );
    }

    function placeLimitOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 encodedTif,
        uint128 cloid
    ) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(
                uint8(1),
                HLConstants.LIMIT_ORDER_ACTION,
                abi.encode(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid)
            )
        );
    }

    function addApiWallet(address wallet, string memory name) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.ADD_API_WALLET_ACTION, abi.encode(wallet, name))
        );
    }

    function cancelOrderByOrderId(uint32 asset, uint64 orderId) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.CANCEL_ORDER_BY_OID_ACTION, abi.encode(asset, orderId))
        );
    }

    function cancelOrderByCloid(uint32 asset, uint128 cloid) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(uint8(1), HLConstants.CANCEL_ORDER_BY_CLOID_ACTION, abi.encode(asset, cloid))
        );
    }

    function finalizeEvmContract(uint64 token, uint8 encodedVariant, uint64 createNonce) internal {
        coreWriter.sendRawAction(
            abi.encodePacked(
                uint8(1),
                HLConstants.FINALIZE_EVM_CONTRACT_ACTION,
                abi.encode(token, encodedVariant, createNonce)
            )
        );
    }
}
