// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { PrecompileLib } from "../../../src/PrecompileLib.sol";
import { RealL1Read } from "../../utils/RealL1Read.sol";

import { CoreState } from "./CoreState.sol";

/// Modified from https://github.com/ambitlabsxyz/hypercore
contract CoreView is CoreState {
    using EnumerableSet for EnumerableSet.AddressSet;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using SafeCast for uint256;

    function tokenExists(uint32 token) public view returns (bool) {
        return bytes(_tokens[token].name).length > 0;
    }

    function readMarkPx(uint32 perp) public returns (uint64) {
        if (_perpMarkPrice[perp] == 0) {
            return RealL1Read.markPx(perp);
        }

        return _perpMarkPrice[perp];
    }

    function readSpotPx(uint32 spotMarketId) public view returns (uint64) {
        if (_spotPrice[spotMarketId] == 0) {
            return PrecompileLib.spotPx(spotMarketId);
        }

        return _spotPrice[spotMarketId];
    }

    function readSpotBalance(address account, uint64 token) public returns (PrecompileLib.SpotBalance memory) {
        if (_initializedSpotBalance[account][token] == false) {
            return RealL1Read.spotBalance(account, token);
        }

        return PrecompileLib.SpotBalance({ total: _accounts[account].spot[token], entryNtl: 0, hold: 0 });
    }

    // Even if the HyperCore account is not created, the precompile returns 0 (it does not revert)
    function readWithdrawable(address account) public returns (PrecompileLib.Withdrawable memory) {
        if (_accounts[account].activated == false) {
            return RealL1Read.withdrawable(account);
        }

        return PrecompileLib.Withdrawable({ withdrawable: _accounts[account].perpBalance });
    }

    function readUserVaultEquity(
        address user,
        address vault
    ) public view returns (PrecompileLib.UserVaultEquity memory) {
        PrecompileLib.UserVaultEquity memory equity = _accounts[user].vaultEquity[vault];
        uint64 multiplier = _vaultMultiplier[vault];
        if (multiplier != 0) equity.equity = uint64((uint256(equity.equity) * multiplier) / 1e18);
        return equity;
    }

    function readDelegation(
        address user,
        address validator
    ) public view returns (PrecompileLib.Delegation memory delegation) {
        delegation.validator = validator;
        delegation.amount = _accounts[user].delegations[validator].amount;
        delegation.lockedUntilTimestamp = _accounts[user].delegations[validator].lockedUntilTimestamp;
    }

    function readDelegations(address user) public view returns (PrecompileLib.Delegation[] memory userDelegations) {
        address[] memory validators = _validators.values();

        userDelegations = new PrecompileLib.Delegation[](validators.length);
        for (uint256 i; i < userDelegations.length; i++) {
            userDelegations[i].validator = validators[i];

            PrecompileLib.Delegation memory delegation = _accounts[user].delegations[validators[i]];
            userDelegations[i].amount = delegation.amount;
            userDelegations[i].lockedUntilTimestamp = delegation.lockedUntilTimestamp;
        }
    }

    function readDelegatorSummary(address user) public view returns (PrecompileLib.DelegatorSummary memory summary) {
        address[] memory validators = _validators.values();

        for (uint256 i; i < validators.length; i++) {
            PrecompileLib.Delegation memory delegation = _accounts[user].delegations[validators[i]];
            summary.delegated += delegation.amount;
        }

        summary.undelegated = _accounts[user].staking;

        for (uint256 i; i < _withdrawQueue.length(); i++) {
            WithdrawRequest memory request = deserializeWithdrawRequest(_withdrawQueue.at(i));
            if (request.account == user) {
                summary.nPendingWithdrawals++;
                summary.totalPendingWithdrawal += request.amount;
            }
        }
    }

    function readPosition(address user, uint16 perp) public view returns (PrecompileLib.Position memory) {
        return _accounts[user].positions[perp];
    }

    function coreUserExists(address account) public returns (bool) {
        if (_accounts[account].activated == false) {
            return RealL1Read.coreUserExists(account).exists;
        }

        return _accounts[account].activated;
    }

    function readAccountMarginSummary(address user) public view returns (PrecompileLib.AccountMarginSummary memory) {
        // 1. maintain an enumerable set for the perps that a user is in
        // 2. iterate over their positions and calculate position value, add them up (value = abs(sz * markPx))
        return PrecompileLib.accountMarginSummary(0, user);
    }

    function readTokenInfo(uint64 index) public view returns (PrecompileLib.TokenInfo memory) {
        return _tokens[index];
    }
}
