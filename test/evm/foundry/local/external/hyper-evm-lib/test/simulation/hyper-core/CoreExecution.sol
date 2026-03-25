// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import { Heap } from "@openzeppelin/contracts/utils/structs/Heap.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { PrecompileLib } from "../../../src/PrecompileLib.sol";
import { CoreWriterLib } from "../../../src/CoreWriterLib.sol";
import { HLConversions } from "../../../src/common/HLConversions.sol";

import { RealL1Read } from "../../utils/RealL1Read.sol";
import { CoreView } from "./CoreView.sol";

contract CoreExecution is CoreView {
    using SafeCast for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using Heap for Heap.Uint256Heap;
    using SafeERC20 for IERC20;
    using RealL1Read for *;

    using EnumerableSet for EnumerableSet.UintSet;

    EnumerableSet.Bytes32Set private _openPerpPositions;

    // Maps user address to a set of perp indices they have active positions in
    mapping(address => EnumerableSet.UintSet) private _userPerpPositions;

    uint16 constant MAX_PERP_INDEX = 256; // Adjust based on expected number of perp markets
    uint64 constant MM_BPS = 125; // 1.25% maintenance margin fraction (adjust as needed, e.g., for 40x max leverage)

    function _getKey(address user, uint16 perpIndex) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(user)) << 16) | uint256(perpIndex));
    }

    function executeTokenTransfer(
        address,
        uint64 token,
        address from,
        uint256 value
    ) public payable initAccountWithToken(from, token) {
        if (_accounts[from].activated) {
            _accounts[from].spot[token] += toWei(value, _tokens[token].evmExtraWeiDecimals);
        } else {
            _latentSpotBalance[from][token] += toWei(value, _tokens[token].evmExtraWeiDecimals);
        }
    }

    function executeNativeTransfer(
        address,
        address from,
        uint256 value
    ) public payable initAccountWithToken(from, HYPE_TOKEN_INDEX) {
        if (_accounts[from].activated) {
            _accounts[from].spot[HYPE_TOKEN_INDEX] += (value / 1e10).toUint64();
        } else {
            _latentSpotBalance[from][HYPE_TOKEN_INDEX] += (value / 1e10).toUint64();
        }
    }

    function executePerpLimitOrder(
        address sender,
        LimitOrderAction memory action
    ) public initAccountWithPerp(sender, uint16(action.asset)) {
        uint16 perpIndex = uint16(action.asset);
        PrecompileLib.Position memory position = _accounts[sender].positions[perpIndex];

        bool isolated = position.isIsolated;

        uint256 markPx = PrecompileLib.markPx(perpIndex);

        if (!isolated) {
            if (action.isBuy) {
                if (markPx <= action.limitPx) {
                    _executePerpLong(sender, action, markPx);
                }
            } else {
                if (markPx >= action.limitPx) {
                    _executePerpShort(sender, action, markPx);
                }
            }
        }
    }

    function _executePerpLong(address sender, LimitOrderAction memory action, uint256 markPx) internal {
        uint16 perpIndex = uint16(action.asset);
        int64 szi = _accounts[sender].positions[perpIndex].szi;
        uint32 leverage = _accounts[sender].positions[perpIndex].leverage;

        uint64 _markPx = markPx.toUint64();

        // Add require checks for safety (e.g., leverage > 0, action.sz > 0, etc.)
        require(leverage > 0, "Invalid leverage");
        require(action.sz > 0, "Invalid size");
        require(markPx > 0, "Invalid price");
        int64 newSzi = szi + int64(action.sz);

        if (szi >= 0) {
            // No PnL realization for same-direction increase
            // Update position size (more positive for long)
            _accounts[sender].positions[perpIndex].szi += int64(action.sz);

            // Additive update to entryNtl to preserve weighted average
            // New entryNtl = old_entryNtl + (action.sz * markPx)
            _accounts[sender].positions[perpIndex].entryNtl += uint64(action.sz) * uint64(markPx);

            // Deduct additional margin for the added size only
            // To minimize integer truncation: (action.sz * markPx) / leverage
            _accounts[sender].perpBalance -= (uint64(action.sz) * uint64(markPx)) / leverage;

            _accounts[sender].margin[perpIndex] += (uint64(action.sz) * uint64(markPx)) / leverage;
        } else {
            if (newSzi <= 0) {
                uint64 avgEntryPrice = _accounts[sender].positions[perpIndex].entryNtl / uint64(-szi);
                int64 pnl = int64(action.sz) * (int64(avgEntryPrice) - int64(_markPx));

                uint64 closedMargin = ((uint64(action.sz) * _accounts[sender].positions[perpIndex].entryNtl) /
                    uint64(-szi)) / leverage;
                _accounts[sender].perpBalance += closedMargin;

                _accounts[sender].perpBalance = pnl > 0
                    ? _accounts[sender].perpBalance + uint64(pnl)
                    : _accounts[sender].perpBalance - uint64(-pnl);
                _accounts[sender].margin[perpIndex] -= closedMargin;

                _accounts[sender].positions[perpIndex].szi = newSzi;
                _accounts[sender].positions[perpIndex].entryNtl = uint64(-newSzi) * avgEntryPrice;
            } else {
                uint64 avgEntryPrice = _accounts[sender].positions[perpIndex].entryNtl / uint64(-szi);
                int64 pnl = int64(-szi) * (int64(avgEntryPrice) - int64(_markPx));
                _accounts[sender].perpBalance = pnl > 0
                    ? _accounts[sender].perpBalance + uint64(pnl)
                    : _accounts[sender].perpBalance - uint64(-pnl);
                uint64 oldMargin = _accounts[sender].positions[perpIndex].entryNtl / leverage;
                _accounts[sender].perpBalance += oldMargin;
                uint64 newLongSize = uint64(newSzi);
                uint64 newMargin = (newLongSize * _markPx) / leverage;
                _accounts[sender].perpBalance -= newMargin;
                _accounts[sender].margin[perpIndex] += newMargin;
                _accounts[sender].positions[perpIndex].szi = newSzi;
                _accounts[sender].positions[perpIndex].entryNtl = newLongSize * _markPx;
            }
        }

        bytes32 key = _getKey(sender, perpIndex);
        if (szi == 0 && newSzi != 0) {
            _openPerpPositions.add(key);
            _userPerpPositions[sender].add(perpIndex);
        } else if (szi != 0 && newSzi == 0) {
            _openPerpPositions.remove(key);
            _userPerpPositions[sender].remove(perpIndex);
        }
    }

    function _executePerpShort(address sender, LimitOrderAction memory action, uint256 markPx) internal {
        uint16 perpIndex = uint16(action.asset);
        int64 szi = _accounts[sender].positions[perpIndex].szi;
        uint32 leverage = _accounts[sender].positions[perpIndex].leverage;

        uint64 _markPx = markPx.toUint64();

        // Add require checks for safety (e.g., leverage > 0, action.sz > 0, etc.)
        require(leverage > 0, "Invalid leverage");
        require(action.sz > 0, "Invalid size");
        require(markPx > 0, "Invalid price");
        int64 newSzi = szi - int64(action.sz);

        if (szi <= 0) {
            // No PnL realization for same-direction increase
            // Update position size (more negative for short)
            _accounts[sender].positions[perpIndex].szi -= int64(action.sz);

            // Additive update to entryNtl to preserve weighted average
            // New entryNtl = old_entryNtl + (action.sz * markPx)
            _accounts[sender].positions[perpIndex].entryNtl += uint64(action.sz) * uint64(markPx);

            // Deduct additional margin for the added size only
            // To minimize integer truncation: (action.sz * markPx) / leverage
            _accounts[sender].perpBalance -= (uint64(action.sz) * uint64(markPx)) / leverage;

            _accounts[sender].margin[perpIndex] += (uint64(action.sz) * uint64(markPx)) / leverage;
        } else {
            if (newSzi >= 0) {
                uint64 avgEntryPrice = _accounts[sender].positions[perpIndex].entryNtl / uint64(szi);
                int64 pnl = int64(action.sz) * (int64(_markPx) - int64(avgEntryPrice));
                uint64 closedMargin = ((uint64(action.sz) * _accounts[sender].positions[perpIndex].entryNtl) /
                    uint64(szi)) / leverage;
                _accounts[sender].perpBalance += closedMargin;

                _accounts[sender].perpBalance = pnl > 0
                    ? _accounts[sender].perpBalance + uint64(pnl)
                    : _accounts[sender].perpBalance - uint64(-pnl);

                _accounts[sender].margin[perpIndex] -= closedMargin;
                _accounts[sender].positions[perpIndex].szi = newSzi;
                _accounts[sender].positions[perpIndex].entryNtl = uint64(newSzi) * avgEntryPrice;
            } else {
                uint64 avgEntryPrice = _accounts[sender].positions[perpIndex].entryNtl / uint64(szi);
                int64 pnl = int64(szi) * (int64(_markPx) - int64(avgEntryPrice));
                _accounts[sender].perpBalance = pnl > 0
                    ? _accounts[sender].perpBalance + uint64(pnl)
                    : _accounts[sender].perpBalance - uint64(-pnl);
                uint64 oldMargin = _accounts[sender].positions[perpIndex].entryNtl / leverage;
                _accounts[sender].perpBalance += oldMargin;
                uint64 newShortSize = uint64(-newSzi);
                uint64 newMargin = (newShortSize * _markPx) / leverage;
                _accounts[sender].perpBalance -= newMargin;
                _accounts[sender].margin[perpIndex] += newMargin;
                _accounts[sender].positions[perpIndex].szi = newSzi;
                _accounts[sender].positions[perpIndex].entryNtl = newShortSize * _markPx;
            }
        }

        bytes32 key = _getKey(sender, perpIndex);
        if (szi == 0 && newSzi != 0) {
            _openPerpPositions.add(key);
            _userPerpPositions[sender].add(perpIndex);
        } else if (szi != 0 && newSzi == 0) {
            _openPerpPositions.remove(key);
            _userPerpPositions[sender].remove(perpIndex);
        }

        // Optional: Add margin sufficiency check after updates
        // e.g., require(_accounts[sender].perpBalance >= someMaintenanceMargin, "Insufficient margin");
    }

    // basic simulation of spot trading, not accounting for orderbook depth, or fees
    function executeSpotLimitOrder(
        address sender,
        LimitOrderAction memory action
    ) public initAccountWithSpotMarket(sender, uint32(HLConversions.assetToSpotId(action.asset))) {
        PrecompileLib.SpotInfo memory spotInfo = RealL1Read.spotInfo(uint32(HLConversions.assetToSpotId(action.asset)));

        PrecompileLib.TokenInfo memory baseToken = _tokens[spotInfo.tokens[0]];

        uint64 spotPx = readSpotPx(uint32(HLConversions.assetToSpotId(action.asset)));

        uint64 fromToken;
        uint64 toToken;

        if (isActionExecutable(action, spotPx)) {
            if (action.isBuy) {
                fromToken = spotInfo.tokens[1];
                toToken = spotInfo.tokens[0];

                uint64 amountIn = action.sz * spotPx;
                uint64 amountOut = action.sz * (10 ** (baseToken.weiDecimals - baseToken.szDecimals)).toUint64();

                if (_accounts[sender].spot[fromToken] >= amountIn) {
                    _accounts[sender].spot[fromToken] -= amountIn;
                    _accounts[sender].spot[toToken] += amountOut;
                } else {
                    revert("insufficient balance");
                }
            } else {
                fromToken = spotInfo.tokens[0];
                toToken = spotInfo.tokens[1];

                uint64 amountIn = action.sz * (10 ** (baseToken.weiDecimals - baseToken.szDecimals)).toUint64();

                uint64 amountOut = action.sz * spotPx;

                if (_accounts[sender].spot[fromToken] >= amountIn) {
                    _accounts[sender].spot[fromToken] -= amountIn;
                    _accounts[sender].spot[toToken] += amountOut;
                } else {
                    revert("insufficient balance");
                }
            }
        } else {
            _pendingOrders.push(PendingOrder({ sender: sender, action: action }));
        }
    }

    function executeSpotSend(
        address sender,
        SpotSendAction memory action
    )
        public
        whenActivated(sender)
        initAccountWithToken(sender, action.token)
        initAccountWithToken(action.destination, action.token)
    {
        if (action._wei > _accounts[sender].spot[action.token]) {
            revert("insufficient balance");
        }

        // handle account activation case
        if (_accounts[action.destination].activated == false) {
            _chargeUSDCFee(sender);

            _accounts[action.destination].activated = true;

            _accounts[sender].spot[action.token] -= action._wei;
            _accounts[action.destination].spot[action.token] += _latentSpotBalance[sender][action.token] + action._wei;

            // this will no longer be needed
            _latentSpotBalance[sender][action.token] = 0;

            // officially init the destination account
            _initializedAccounts[action.destination] = true;
            _initializedSpotBalance[action.destination][action.token] = true;
            return;
        }

        address systemAddress = CoreWriterLib.getSystemAddress(action.token);

        _accounts[sender].spot[action.token] -= action._wei;

        if (action.destination != systemAddress) {
            _accounts[action.destination].spot[action.token] += action._wei;
        } else {
            uint256 transferAmount;
            if (action.token == HYPE_TOKEN_INDEX) {
                transferAmount = action._wei * 1e10;
                deal(systemAddress, systemAddress.balance + transferAmount);
                vm.prank(systemAddress);
                (bool success, ) = address(sender).call{ value: transferAmount, gas: 30000 }("");
                if (!success) {
                    revert("transfer failed");
                }
                return;
            }

            address evmContract = _tokens[action.token].evmContract;
            transferAmount = fromWei(action._wei, _tokens[action.token].evmExtraWeiDecimals);
            deal(evmContract, systemAddress, IERC20(evmContract).balanceOf(systemAddress) + transferAmount);
            vm.prank(systemAddress);
            IERC20(evmContract).safeTransfer(action.destination, transferAmount);
        }
    }

    function _chargeUSDCFee(address sender) internal {
        if (_accounts[sender].spot[USDC_TOKEN_INDEX] >= 1e8) {
            _accounts[sender].spot[USDC_TOKEN_INDEX] -= 1e8;
        } else if (_accounts[sender].perpBalance >= 1e8) {
            _accounts[sender].perpBalance -= 1e8;
        } else {
            revert("insufficient USDC balance for fee");
        }
    }

    function executeUsdClassTransfer(
        address sender,
        UsdClassTransferAction memory action
    ) public whenActivated(sender) {
        if (action.toPerp) {
            if (fromPerp(action.ntl) <= _accounts[sender].spot[USDC_TOKEN_INDEX]) {
                _accounts[sender].perpBalance += action.ntl;
                _accounts[sender].spot[USDC_TOKEN_INDEX] -= fromPerp(action.ntl);
            }
        } else {
            if (action.ntl <= _accounts[sender].perpBalance) {
                _accounts[sender].perpBalance -= action.ntl;
                _accounts[sender].spot[USDC_TOKEN_INDEX] += fromPerp(action.ntl);
            }
        }
    }

    function executeVaultTransfer(
        address sender,
        VaultTransferAction memory action
    ) public whenActivated(sender) initAccountWithVault(sender, action.vault) {
        // first update their vault equity
        _accounts[sender].vaultEquity[action.vault].equity = readUserVaultEquity(sender, action.vault).equity;

        if (action.isDeposit) {
            if (action.usd <= _accounts[sender].perpBalance) {
                _accounts[sender].vaultEquity[action.vault].equity += action.usd;
                _accounts[sender].vaultEquity[action.vault].lockedUntilTimestamp = uint64(
                    (block.timestamp + 86400) * 1000
                );
                _accounts[sender].perpBalance -= action.usd;
                _vaultEquity[action.vault] += action.usd;
            } else {
                revert("insufficient balance");
            }
        } else {
            PrecompileLib.UserVaultEquity storage userVaultEquity = _accounts[sender].vaultEquity[action.vault];

            // a zero amount means withdraw the entire amount
            action.usd = action.usd == 0 ? userVaultEquity.equity : action.usd;

            // the vaults have a minimum withdraw of 1 / 100,000,000
            if (action.usd < _vaultEquity[action.vault] / 1e8) {
                revert("does not meet minimum withdraw");
            }

            if (
                action.usd <= userVaultEquity.equity && userVaultEquity.lockedUntilTimestamp / 1000 <= block.timestamp
            ) {
                userVaultEquity.equity -= action.usd;
                _accounts[sender].perpBalance += action.usd;
            } else {
                revert("equity too low, or locked");
            }
        }
    }

    function executeStakingDeposit(address sender, StakingDepositAction memory action) public whenActivated(sender) {
        if (action._wei <= _accounts[sender].spot[HYPE_TOKEN_INDEX]) {
            _accounts[sender].spot[HYPE_TOKEN_INDEX] -= action._wei;
            _accounts[sender].staking += action._wei;
        }
    }

    function executeStakingWithdraw(address sender, StakingWithdrawAction memory action) public whenActivated(sender) {
        if (action._wei <= _accounts[sender].staking) {
            _accounts[sender].staking -= action._wei;

            WithdrawRequest memory withrawRequest = WithdrawRequest({
                account: sender,
                amount: action._wei,
                lockedUntilTimestamp: uint32(block.timestamp + 7 days)
            });

            _withdrawQueue.pushBack(serializeWithdrawRequest(withrawRequest));
        }
    }

    function executeTokenDelegate(address sender, TokenDelegateAction memory action) public whenActivated(sender) {
        require(_validators.contains(action.validator));

        if (action.isUndelegate) {
            PrecompileLib.Delegation storage delegation = _accounts[sender].delegations[action.validator];
            if (action._wei <= delegation.amount && block.timestamp * 1000 > delegation.lockedUntilTimestamp) {
                _accounts[sender].staking += action._wei;
                delegation.amount -= action._wei;
            }
        } else {
            if (action._wei <= _accounts[sender].staking) {
                _accounts[sender].staking -= action._wei;
                _accounts[sender].delegations[action.validator].amount += action._wei;
                _accounts[sender].delegations[action.validator].lockedUntilTimestamp = ((block.timestamp + 84600) *
                    1000).toUint64();
            }
        }
    }

    function setMarkPx(uint32 perp, uint64 priceDiffBps, bool isIncrease) public {
        uint64 basePrice = readMarkPx(perp);
        if (isIncrease) {
            _perpMarkPrice[perp] = (basePrice * (10000 + priceDiffBps)) / 10000;
        } else {
            _perpMarkPrice[perp] = (basePrice * (10000 - priceDiffBps)) / 10000;
        }
    }

    function setMarkPx(uint32 perp, uint64 markPx) public {
        _perpMarkPrice[perp] = markPx;
    }

    function setSpotPx(uint32 spotMarketId, uint64 priceDiffBps, bool isIncrease) public {
        uint64 basePrice = readSpotPx(spotMarketId);
        if (isIncrease) {
            _spotPrice[spotMarketId] = (basePrice * (10000 + priceDiffBps)) / 10000;
        } else {
            _spotPrice[spotMarketId] = (basePrice * (10000 - priceDiffBps)) / 10000;
        }
    }

    function setSpotPx(uint32 spotMarketId, uint64 spotPx) public {
        _spotPrice[spotMarketId] = spotPx;
    }

    function isActionExecutable(LimitOrderAction memory action, uint64 px) internal pure returns (bool) {
        bool executable = action.isBuy ? action.limitPx >= px : action.limitPx <= px;
        return executable;
    }

    function setVaultMultiplier(address vault, uint64 multiplier) public {
        _vaultMultiplier[vault] = multiplier;
    }

    function processPendingOrders() public {
        for (uint256 i = _pendingOrders.length; i > 0; i--) {
            PendingOrder memory order = _pendingOrders[i - 1];
            uint32 spotMarketId = order.action.asset - 1e4;
            uint64 spotPx = readSpotPx(spotMarketId);

            if (isActionExecutable(order.action, spotPx)) {
                executeSpotLimitOrder(order.sender, order.action);

                // Remove executed order by swapping with last and popping
                _pendingOrders[i - 1] = _pendingOrders[_pendingOrders.length - 1];
                _pendingOrders.pop();
            }
        }
    }

    ////////// PERP LIQUIDATIONS ////////////////////
    function isLiquidatable(address user) public returns (bool) {
        uint64 totalNotional = 0;
        int64 totalUPnL = 0;
        uint64 totalLocked = 0;
        uint64 mmReq = 0;

        uint256 len = _userPerpPositions[user].length();

        for (uint256 i = len; i > 0; i--) {
            uint16 perpIndex = uint16(_userPerpPositions[user].at(i - 1));
            PrecompileLib.Position memory pos = _accounts[user].positions[perpIndex];
            if (pos.szi != 0) {
                uint64 markPx = readMarkPx(perpIndex);
                int64 szi = pos.szi;
                uint64 avgEntry = pos.entryNtl / abs(szi);
                int64 uPnL = szi * (int64(markPx) - int64(avgEntry));
                totalUPnL += uPnL;
                totalLocked += _accounts[user].margin[perpIndex];

                uint64 positionNotional = abs(szi) * markPx;
                totalNotional += positionNotional;

                // Per-perp maintenance margin requirement based on max leverage
                uint32 maxLev = _getMaxLeverage(perpIndex);
                uint64 mmBps = 5000 / maxLev; // 5000 / maxLev gives bps for mm_fraction = 0.5 / maxLev
                mmReq += (positionNotional * mmBps) / 10000;
            }
        }

        if (totalNotional == 0) {
            return false;
        }

        int64 equity = int64(_accounts[user].perpBalance) + int64(totalLocked) + totalUPnL;

        return equity < int64(mmReq);
    }

    function abs(int64 value) internal pure returns (uint64) {
        return value > 0 ? uint64(value) : uint64(-value);
    }

    function _getMaxLeverage(uint16 perpIndex) public view returns (uint32) {
        return _maxLeverage[perpIndex];
    }

    // simplified liquidation, nukes all positions and resets the perp balance
    // for future: make this more realistic
    function _liquidateUser(address user) public {
        uint256 len = _userPerpPositions[user].length();
        for (uint256 i = len; i > 0; i--) {
            uint16 perpIndex = uint16(_userPerpPositions[user].at(i - 1));

            bytes32 key = _getKey(user, perpIndex);
            _openPerpPositions.remove(key);
            _accounts[user].positions[perpIndex].szi = 0;
            _accounts[user].positions[perpIndex].entryNtl = 0;
            _accounts[user].margin[perpIndex] = 0;
            _userPerpPositions[user].remove(perpIndex);
        }

        _accounts[user].perpBalance = 0;
    }

    function liquidatePositions() public {
        uint256 len = _openPerpPositions.length();

        if (len == 0) return;

        for (uint256 i = len; i > 0; i--) {
            bytes32 key = _openPerpPositions.at(i - 1);
            address user = address(uint160(uint256(key) >> 16));
            if (isLiquidatable(user)) {
                _liquidateUser(user);
            }
        }
    }
}
