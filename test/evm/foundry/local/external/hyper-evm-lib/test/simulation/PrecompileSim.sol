// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { HyperCore } from "./HyperCore.sol";

import { Vm } from "forge-std/Vm.sol";

/// @dev this contract is deployed for each different precompile address such that the fallback can be executed for each
contract PrecompileSim {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    HyperCore constant _hyperCore = HyperCore(payable(0x9999999999999999999999999999999999999999));

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

    receive() external payable {}

    fallback(bytes calldata data) external returns (bytes memory) {
        if (address(this) == SPOT_BALANCE_PRECOMPILE_ADDRESS) {
            (address user, uint64 token) = abi.decode(data, (address, uint64));
            return abi.encode(_hyperCore.readSpotBalance(user, token));
        }

        if (address(this) == VAULT_EQUITY_PRECOMPILE_ADDRESS) {
            (address user, address vault) = abi.decode(data, (address, address));
            return abi.encode(_hyperCore.readUserVaultEquity(user, vault));
        }

        if (address(this) == WITHDRAWABLE_PRECOMPILE_ADDRESS) {
            address user = abi.decode(data, (address));
            return abi.encode(_hyperCore.readWithdrawable(user));
        }

        if (address(this) == DELEGATIONS_PRECOMPILE_ADDRESS) {
            address user = abi.decode(data, (address));
            return abi.encode(_hyperCore.readDelegations(user));
        }

        if (address(this) == DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS) {
            address user = abi.decode(data, (address));
            return abi.encode(_hyperCore.readDelegatorSummary(user));
        }

        if (address(this) == POSITION_PRECOMPILE_ADDRESS) {
            (address user, uint16 perp) = abi.decode(data, (address, uint16));
            return abi.encode(_hyperCore.readPosition(user, perp));
        }

        if (address(this) == CORE_USER_EXISTS_PRECOMPILE_ADDRESS) {
            address user = abi.decode(data, (address));
            return abi.encode(_hyperCore.coreUserExists(user));
        }

        if (address(this) == MARK_PX_PRECOMPILE_ADDRESS) {
            uint32 perp = abi.decode(data, (uint32));
            return abi.encode(_hyperCore.readMarkPx(perp));
        }

        if (address(this) == ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS) {
            address user = abi.decode(data, (address));
            return abi.encode(_hyperCore.readAccountMarginSummary(user));
        }

        if (address(this) == TOKEN_INFO_PRECOMPILE_ADDRESS) {
            uint64 index = abi.decode(data, (uint64));
            return abi.encode(_hyperCore.readTokenInfo(index));
        }

        return _makeRpcCall(address(this), data);
    }

    function _makeRpcCall(address target, bytes memory params) internal returns (bytes memory) {
        // Construct the JSON-RPC payload
        string memory jsonPayload = string.concat(
            '[{"to":"',
            vm.toString(target),
            '","data":"',
            vm.toString(params),
            '"},"latest"]'
        );

        // Make the RPC call
        return vm.rpc("eth_call", jsonPayload);
    }
}
