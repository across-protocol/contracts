// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Vm } from "forge-std/Vm.sol";

import { HyperCore } from "./HyperCore.sol";
import { CoreWriterSim } from "./CoreWriterSim.sol";
import { PrecompileSim } from "./PrecompileSim.sol";

import { HLConstants } from "../../src/PrecompileLib.sol";

Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));
CoreWriterSim constant coreWriter = CoreWriterSim(0x3333333333333333333333333333333333333333);

contract HypeSystemContract {
    receive() external payable {
        coreWriter.nativeTransferCallback{ value: msg.value }(msg.sender, msg.sender, msg.value);
    }
}

/**
 * @title CoreSimulatorLib
 * @dev A library used to simulate HyperCore functionality in foundry tests
 */
library CoreSimulatorLib {
    uint256 constant NUM_PRECOMPILES = 17;

    HyperCore constant hyperCore = HyperCore(payable(0x9999999999999999999999999999999999999999));

    // ERC20 Transfer event signature
    bytes32 constant TRANSFER_EVENT_SIG = keccak256("Transfer(address,address,uint256)");

    function init() internal returns (HyperCore) {
        vm.pauseGasMetering();

        HyperCore coreImpl = new HyperCore();

        vm.etch(address(hyperCore), address(coreImpl).code);
        vm.etch(address(coreWriter), type(CoreWriterSim).runtimeCode);

        // Initialize precompiles
        for (uint160 i = 0; i < NUM_PRECOMPILES; i++) {
            address precompileAddress = address(uint160(0x0000000000000000000000000000000000000800) + i);
            vm.etch(precompileAddress, type(PrecompileSim).runtimeCode);
            vm.allowCheatcodes(precompileAddress);
        }

        // System addresses
        address hypeSystemAddress = address(0x2222222222222222222222222222222222222222);
        vm.etch(hypeSystemAddress, type(HypeSystemContract).runtimeCode);

        // Start recording logs for token transfer tracking
        vm.recordLogs();

        vm.allowCheatcodes(address(hyperCore));
        vm.allowCheatcodes(address(coreWriter));

        vm.resumeGasMetering();

        return hyperCore;
    }

    function nextBlock() internal {
        // Get all recorded logs
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Process any ERC20 transfers to system addresses (EVM->Core transfers are processed before CoreWriter actions)
        for (uint256 i = 0; i < entries.length; i++) {
            Vm.Log memory entry = entries[i];

            // Check if it's a Transfer event
            if (entry.topics[0] == TRANSFER_EVENT_SIG) {
                address from = address(uint160(uint256(entry.topics[1])));
                address to = address(uint160(uint256(entry.topics[2])));
                uint256 amount = abi.decode(entry.data, (uint256));

                // Check if destination is a system address
                if (isSystemAddress(to)) {
                    uint64 tokenIndex = getTokenIndexFromSystemAddress(to);

                    // Call tokenTransferCallback on HyperCoreWrite
                    hyperCore.executeTokenTransfer(address(0), tokenIndex, from, amount);
                }
            }
        }

        // Clear recorded logs for next block
        vm.recordLogs();

        // Advance block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);

        // liquidate any positions that are liquidatable
        hyperCore.liquidatePositions();

        // Process any pending actions
        coreWriter.executeQueuedActions();

        // Process pending orders
        hyperCore.processPendingOrders();
    }

    ////// TESTING CONFIG SETTERS /////////

    function setRevertOnFailure(bool _revertOnFailure) internal {
        coreWriter.setRevertOnFailure(_revertOnFailure);
    }

    // cheatcodes //
    function forceAccountActivation(address account) internal {
        hyperCore.forceAccountActivation(account);
    }

    function forceSpot(address account, uint64 token, uint64 _wei) internal {
        hyperCore.forceSpot(account, token, _wei);
    }

    function forceTokenInfo(
        uint64 index,
        string memory name,
        address evmContract,
        uint8 szDecimals,
        uint8 weiDecimals,
        int8 evmExtraWeiDecimals
    ) internal {
        hyperCore.forceTokenInfo(index, name, evmContract, szDecimals, weiDecimals, evmExtraWeiDecimals);
    }

    function forcePerpBalance(address account, uint64 usd) internal {
        hyperCore.forcePerpBalance(account, usd);
    }

    function forceStaking(address account, uint64 _wei) internal {
        hyperCore.forceStaking(account, _wei);
    }

    function forceDelegation(address account, address validator, uint64 amount, uint64 lockedUntilTimestamp) internal {
        hyperCore.forceDelegation(account, validator, amount, lockedUntilTimestamp);
    }

    function forceVaultEquity(address account, address vault, uint64 usd, uint64 lockedUntilTimestamp) internal {
        hyperCore.forceVaultEquity(account, vault, usd, lockedUntilTimestamp);
    }

    function setMarkPx(uint32 perp, uint64 markPx) internal {
        hyperCore.setMarkPx(perp, markPx);
    }

    function setMarkPx(uint32 perp, uint64 priceDiffBps, bool isIncrease) internal {
        hyperCore.setMarkPx(perp, priceDiffBps, isIncrease);
    }

    function setSpotPx(uint32 spotMarketId, uint64 spotPx) internal {
        hyperCore.setSpotPx(spotMarketId, spotPx);
    }

    function setSpotPx(uint32 spotMarketId, uint64 priceDiffBps, bool isIncrease) internal {
        hyperCore.setSpotPx(spotMarketId, priceDiffBps, isIncrease);
    }

    function setVaultMultiplier(address vault, uint64 multiplier) internal {
        hyperCore.setVaultMultiplier(vault, multiplier);
    }

    ///// VIEW AND PURE /////////

    function isSystemAddress(address addr) internal view returns (bool) {
        // Check if it's the HYPE system address
        if (addr == address(0x2222222222222222222222222222222222222222)) {
            return true;
        }

        // Check if it's a token system address (0x2000...0000 + index)
        uint160 baseAddr = uint160(0x2000000000000000000000000000000000000000);
        uint160 addrInt = uint160(addr);

        if (addrInt >= baseAddr && addrInt < baseAddr + 10000) {
            uint64 tokenIndex = uint64(addrInt - baseAddr);

            return tokenExists(tokenIndex);
        }

        return false;
    }

    function getTokenIndexFromSystemAddress(address systemAddr) internal pure returns (uint64) {
        if (systemAddr == address(0x2222222222222222222222222222222222222222)) {
            return 150; // HYPE token index
        }
        return uint64(uint160(systemAddr) - uint160(0x2000000000000000000000000000000000000000));
    }

    function tokenExists(uint64 token) internal view returns (bool) {
        (bool success, ) = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(token));
        return success;
    }
}
