// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ICoreWriter } from "../interfaces/ICoreWriter.sol";

library HLConstants {
    /*//////////////////////////////////////////////////////////////
                        Addresses
    //////////////////////////////////////////////////////////////*/

    address constant POSITION_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000800;
    address constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address constant VAULT_EQUITY_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000802;
    address constant WITHDRAWABLE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000803;
    address constant DELEGATIONS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000804;
    address constant DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000805;
    address constant MARK_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000806;
    address constant ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;
    address constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address constant L1_BLOCK_NUMBER_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000809;
    address constant PERP_ASSET_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080a;
    address constant SPOT_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080b;
    address constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;
    address constant TOKEN_SUPPLY_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080D;
    address constant BBO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080e;
    address constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080F;
    address constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;

    uint160 constant BASE_SYSTEM_ADDRESS = uint160(0x2000000000000000000000000000000000000000);
    address constant HYPE_SYSTEM_ADDRESS = 0x2222222222222222222222222222222222222222;

    uint8 constant HYPE_EVM_EXTRA_DECIMALS = 10;

    /*//////////////////////////////////////////////////////////////
                        HYPE Token Index
    //////////////////////////////////////////////////////////////*/
    function hypeTokenIndex() internal view returns (uint64) {
        return block.chainid == 998 ? 1105 : 150;
    }

    function isHype(uint64 index) internal view returns (bool) {
        return index == hypeTokenIndex();
    }

    /*//////////////////////////////////////////////////////////////
                        CoreWriter Actions
    //////////////////////////////////////////////////////////////*/

    uint24 constant LIMIT_ORDER_ACTION = 1;
    uint24 constant VAULT_TRANSFER_ACTION = 2;

    uint24 constant TOKEN_DELEGATE_ACTION = 3;
    uint24 constant STAKING_DEPOSIT_ACTION = 4;
    uint24 constant STAKING_WITHDRAW_ACTION = 5;

    uint24 constant SPOT_SEND_ACTION = 6;
    uint24 constant USD_CLASS_TRANSFER_ACTION = 7;

    uint24 constant FINALIZE_EVM_CONTRACT_ACTION = 8;
    uint24 constant ADD_API_WALLET_ACTION = 9;
    uint24 constant CANCEL_ORDER_BY_OID_ACTION = 10;
    uint24 constant CANCEL_ORDER_BY_CLOID_ACTION = 11;

    /*//////////////////////////////////////////////////////////////
                        Limit Order Time in Force
    //////////////////////////////////////////////////////////////*/

    uint8 public constant LIMIT_ORDER_TIF_ALO = 1;
    uint8 public constant LIMIT_ORDER_TIF_GTC = 2;
    uint8 public constant LIMIT_ORDER_TIF_IOC = 3;
}
