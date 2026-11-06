// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CommonBase } from "forge-std/Base.sol";
import { console } from "forge-std/console.sol";

/// @notice Shared PASS/FAIL/REVIEW logging, counters, assertion helpers and deployed-addresses.json
///         lookups for the counterfactual check scripts (CheckCounterfactualDeployments,
///         CheckCounterfactualBeaconImpls).
///
/// Output prefixes for easy grep:
///   [PASS]   - Auto-check passed
///   [FAIL]   - Auto-check failed (investigate!)
///   [REVIEW] - Manual review needed (always printed, never silently passed)
///   [DIFF]   - A value the pending change would alter (counted as manual review)
///   [INFO]   - Informational
abstract contract CheckUtils is CommonBase {
    string internal deployedAddressesJson;

    uint256 internal totalPass;
    uint256 internal totalFail;
    uint256 internal totalReview;

    function _loadDeployedAddresses() internal {
        deployedAddressesJson = vm.readFile("broadcast/deployed-addresses.json");
    }

    // --- Cached deployed-addresses.json lookups ---

    function _getDeployed(string memory contractName, uint256 chainId) internal view returns (address) {
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].address'
        );
        if (vm.keyExists(deployedAddressesJson, path)) {
            return vm.parseJsonAddress(deployedAddressesJson, path);
        }
        return address(0);
    }

    function _getChainName(uint256 chainId) internal view returns (string memory) {
        string memory path = string.concat('.chains["', vm.toString(chainId), '"].chain_name');
        if (vm.keyExists(deployedAddressesJson, path)) {
            return vm.parseJsonString(deployedAddressesJson, path);
        }
        return string.concat("Chain ", vm.toString(chainId));
    }

    // --- Guarded external reads ---
    // On ZK-stack forks, calls into era-VM accounts can "succeed" with EMPTY returndata; a high-level
    // `try X.f() returns (...)` then reverts UNCATCHABLY in the caller while decoding. Every read of a
    // contract we did not just deploy must go through these low-level helpers.
    //
    // Gas is capped per probe: exotic bytecode the local EVM cannot run (era-VM accounts, TIP-20 system
    // tokens) fails with an all-gas-consuming halt, which would otherwise burn 63/64 of the entire
    // script's remaining gas per occurrence.
    uint256 private constant PROBE_GAS = 500_000;

    /// @dev Staticcalls a getter returning one 32-byte word. ok=false on revert or short returndata.
    function _tryReadWord(address target, bytes memory data) internal view returns (bool ok, bytes32 word) {
        (bool success, bytes memory ret) = target.staticcall{ gas: PROBE_GAS }(data);
        if (!success || ret.length < 32) return (false, 0);
        assembly ("memory-safe") {
            word := mload(add(ret, 32))
        }
        return (true, word);
    }

    /// @dev Reads an ERC-20 `symbol()`, tolerating both string and legacy bytes32 encodings.
    ///      ok=false on revert or malformed returndata.
    function _trySymbol(address token) internal view returns (bool ok, string memory sym) {
        (bool success, bytes memory ret) = token.staticcall{ gas: PROBE_GAS }(abi.encodeWithSignature("symbol()"));
        if (!success || ret.length == 0) return (false, "");
        if (ret.length == 32) {
            // Legacy bytes32-style symbol.
            bytes32 raw;
            assembly ("memory-safe") {
                raw := mload(add(ret, 32))
            }
            uint256 len;
            while (len < 32 && raw[len] != 0) len++;
            bytes memory b = new bytes(len);
            for (uint256 i = 0; i < len; i++) b[i] = raw[i];
            return (true, string(b));
        }
        // Standard string encoding: validate the shape before abi.decode (which reverts uncatchably).
        if (ret.length < 64) return (false, "");
        uint256 offset;
        uint256 strLen;
        assembly ("memory-safe") {
            offset := mload(add(ret, 32))
            strLen := mload(add(ret, 64))
        }
        if (offset != 32 || ret.length < 64 + strLen) return (false, "");
        return (true, abi.decode(ret, (string)));
    }

    // --- Logging helpers ---

    function _pass(string memory contract_, string memory field, string memory value) internal {
        console.log("[PASS]   %s.%s = %s", contract_, field, value);
        totalPass++;
    }

    function _fail(string memory contract_, string memory field, string memory detail) internal {
        console.log("[FAIL]   %s.%s: %s", contract_, field, detail);
        totalFail++;
    }

    function _info(string memory contract_, string memory detail) internal pure {
        console.log("[INFO]   %s: %s", contract_, detail);
    }

    /// @dev Free-form manual-review line (counted, never silently passed).
    function _reviewNote(string memory contract_, string memory note) internal {
        console.log("[REVIEW] %s: %s", contract_, note);
        totalReview++;
    }

    function _assertAddrEq(string memory contract_, string memory field, address actual, address expected) internal {
        if (actual == expected) {
            _pass(contract_, field, vm.toString(actual));
        } else {
            console.log("[FAIL]   %s.%s", contract_, field);
            console.log("           actual:   %s", actual);
            console.log("           expected: %s", expected);
            totalFail++;
        }
    }

    function _assertUintEq(string memory contract_, string memory field, uint256 actual, uint256 expected) internal {
        if (actual == expected) {
            _pass(contract_, field, vm.toString(actual));
        } else {
            console.log("[FAIL]   %s.%s", contract_, field);
            console.log("           actual:   %s", actual);
            console.log("           expected: %s", expected);
            totalFail++;
        }
    }

    /// @dev Prints the run summary and reverts if any auto-check failed.
    function _printSummary() internal view {
        console.log("============================================");
        console.log("SUMMARY: %s passed, %s failed, %s manual review", totalPass, totalFail, totalReview);
        console.log("============================================");
        require(totalFail == 0, "Some auto-checks FAILED");
    }
}
