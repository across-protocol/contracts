// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "../utils/Constants.sol";
import { DeployedAddresses } from "../utils/DeployedAddresses.sol";

/**
 * @title UpdateVkey
 * @notice Generates calldata for updating SP1Helios verification keys across multiple chains. The script queries
 * each chain to verify Helios setup and outputs two equivalent options for the HubPool owner (multisig) to execute:
 *   - Option A: a single HubPool.multicall(bytes[]) where each entry is a relaySpokePoolAdminFunction call.
 *   - Option B: the (chainId, functionData) params for one HubPool.relaySpokePoolAdminFunction call per chain.
 * RPC URLs are read from .env using the NODE_URL_<CHAIN_ID> convention (e.g., NODE_URL_56, NODE_URL_143).
 * Non-EVM chains whose addresses are stored in base58 (e.g. Tron, chainId 728126428) are decoded to their
 * 20-byte EVM form so they can be forked and queried like any other chain; their NODE_URL must point at an
 * EVM-compatible JSON-RPC endpoint (e.g. TronGrid's /jsonrpc).
 *
 *
 * Example:
 *   forge script script/tasks/UpdateVkey.s.sol:UpdateVkey \
 *     --sig "run(bytes32,string)" \
 *     0x1234567890abcdef0000000000000000000000000000000000000000000000 "56,143,999" \
 *     -vvv
 *
 * Arguments:
 *   - newVkey: The new Helios program vkey (bytes32)
 *   - chains: Comma-separated list of chain IDs (e.g., "56,143,999")
 */
contract UpdateVkey is Script, Constants, DeployedAddresses {
    // Expected value for VKEY_UPDATER_ROLE to sanity check on-chain value
    bytes32 constant EXPECTED_VKEY_UPDATER_ROLE = 0x07ecc55c8d82c6f82ef86e34d1905e0f2873c085733fa96f8a6e0316b050d174;

    // Tron mainnet. Its JSON-RPC (TronGrid) is `latest`-only and cannot be forked by Foundry, so on-chain
    // verification is skipped for this chain and calldata is built directly from deployed-addresses.json.
    uint256 constant TRON_CHAIN_ID = 728126428;

    // Struct to hold per-chain call data
    struct ChainCall {
        uint256 chainId;
        address spokePool;
        address helios;
        // `functionData` param for relaySpokePoolAdminFunction(chainId, functionData)
        bytes functionData;
    }

    function run(bytes32 newVkey, string calldata chainsStr) external {
        // Parse chain IDs from argument
        uint256[] memory chainIds = parseChainIds(chainsStr);

        // Get HubPool address (from mainnet)
        address hubPoolAddress = getAddress(1, "HubPool");
        require(hubPoolAddress != address(0), "HubPool not found in deployed-addresses.json");

        console.log("");
        console.log("============ Update Helios Vkey ============");
        console.log("New Vkey:", vm.toString(newVkey));
        console.log("HubPool:", hubPoolAddress);
        console.log("Chains:", chainsStr);
        console.log("--------------------------------------------");

        // Process each chain
        ChainCall[] memory calls = new ChainCall[](chainIds.length);
        uint256 validCallCount = 0;
        uint256[] memory failedChains = new uint256[](chainIds.length);
        uint256 failedCount = 0;
        uint256[] memory upToDateChains = new uint256[](chainIds.length);
        uint256 upToDateCount = 0;

        for (uint256 i = 0; i < chainIds.length; i++) {
            uint256 chainId = chainIds[i];

            // Get SpokePool address for this chain. Use a Tron-aware reader since non-EVM chains (e.g. Tron,
            // chainId 728126428) store base58 addresses in deployed-addresses.json that revert vm.readAddress.
            address spokePoolAddress = readAddressTronAware(chainId, "SpokePool");
            if (spokePoolAddress == address(0)) {
                console.log("Skipping chain %d: no SpokePool in deployed-addresses.json", chainId);
                failedChains[failedCount++] = chainId;
                continue;
            }

            // Resolve the Helios address. EVM chains are forked and verified on-chain; Tron cannot be forked
            // (TronGrid JSON-RPC is `latest`-only), so its Helios is read from deployed-addresses.json unverified.
            address heliosAddress;

            if (chainId == TRON_CHAIN_ID) {
                heliosAddress = readAddressTronAware(chainId, "SP1Helios");
                if (heliosAddress == address(0)) {
                    console.log("Skipping chain %d: no SP1Helios in deployed-addresses.json", chainId);
                    failedChains[failedCount++] = chainId;
                    continue;
                }
                console.log("WARNING: chain %d (Tron) cannot be forked; skipping on-chain role/vkey checks", chainId);
                console.log("  Manually verify SpokePool holds VKEY_UPDATER_ROLE and current vkey != new vkey");
            } else {
                // Get RPC URL for this chain (uses same NODE_URL_<chainId> convention as Hardhat)
                string memory rpcEnvVar = string.concat("NODE_URL_", vm.toString(chainId));
                string memory rpcUrl;
                try vm.envString(rpcEnvVar) returns (string memory url) {
                    rpcUrl = url;
                } catch {
                    console.log("Skipping chain %d: no %s environment variable", chainId, rpcEnvVar);
                    failedChains[failedCount++] = chainId;
                    continue;
                }

                // Fork to this chain
                uint256 forkId = vm.createFork(rpcUrl);
                vm.selectFork(forkId);

                // Get Helios address from SpokePool
                try IUniversalSpokePool(spokePoolAddress).helios() returns (address addr) {
                    heliosAddress = addr;
                } catch {
                    console.log("Skipping chain %d: SpokePool does not expose helios()", chainId);
                    failedChains[failedCount++] = chainId;
                    continue;
                }

                if (heliosAddress == address(0)) {
                    console.log("Skipping chain %d: SpokePool.helios() returned zero address", chainId);
                    failedChains[failedCount++] = chainId;
                    continue;
                }

                // Verify VKEY_UPDATER_ROLE
                bytes32 vkeyRole;
                try ISP1Helios(heliosAddress).VKEY_UPDATER_ROLE() returns (bytes32 role) {
                    vkeyRole = role;
                } catch {
                    console.log("Skipping chain %d: failed to read VKEY_UPDATER_ROLE from Helios", chainId);
                    failedChains[failedCount++] = chainId;
                    continue;
                }

                if (vkeyRole != EXPECTED_VKEY_UPDATER_ROLE) {
                    console.log("Warning: VKEY_UPDATER_ROLE mismatch on chain %d", chainId);
                }

                // Check if SpokePool has the role
                bool hasRole = ISP1Helios(heliosAddress).hasRole(vkeyRole, spokePoolAddress);
                if (!hasRole) {
                    console.log("Skipping chain %d: SpokePool does not have VKEY_UPDATER_ROLE on Helios", chainId);
                    failedChains[failedCount++] = chainId;
                    continue;
                }

                // Check current vkey
                bytes32 currentVkey = ISP1Helios(heliosAddress).heliosProgramVkey();
                if (currentVkey == newVkey) {
                    console.log("Chain %d: Helios already has the requested vkey; skipping", chainId);
                    upToDateChains[upToDateCount++] = chainId;
                    continue;
                }
                console.log("  Current Vkey:", vm.toString(currentVkey));
            }

            console.log("Chain %d: building updateHeliosProgramVkey() call", chainId);
            console.log("  SpokePool:", spokePoolAddress);
            console.log("  Helios:", heliosAddress);

            // Build nested calldata
            // 1. Helios.updateHeliosProgramVkey(newVkey)
            bytes memory heliosCalldata = abi.encodeWithSelector(ISP1Helios.updateHeliosProgramVkey.selector, newVkey);

            // 2. SpokePool.executeExternalCall(message) where message = abi.encode(helios, heliosCalldata)
            bytes memory message = abi.encode(heliosAddress, heliosCalldata);
            bytes memory spokePoolCalldata = abi.encodeWithSelector(
                IUniversalSpokePool.executeExternalCall.selector,
                message
            );

            // spokePoolCalldata is the `functionData` param passed directly to
            // HubPool.relaySpokePoolAdminFunction(chainId, functionData)
            calls[validCallCount++] = ChainCall({
                chainId: chainId,
                spokePool: spokePoolAddress,
                helios: heliosAddress,
                functionData: spokePoolCalldata
            });
        }

        console.log("--------------------------------------------");

        // Check for failures
        if (failedCount > 0) {
            console.log("");
            console.log("ERROR: Failed to prepare vkey update for chains:");
            for (uint256 i = 0; i < failedCount; i++) {
                console.log("  - %d", failedChains[i]);
            }
            revert("One or more chains failed during vkey update preparation");
        }

        // Output results
        console.log("");
        console.log("Generated %d HubPool admin call(s)", validCallCount);

        if (validCallCount == 0) {
            console.log("All requested chains already have the provided Helios vkey; no calldata needed.");
            return;
        }

        console.log("");
        console.log("Per-chain summary:");
        for (uint256 i = 0; i < validCallCount; i++) {
            console.log(
                "  - chainId=%d, spokePool=%s, helios=%s",
                calls[i].chainId,
                calls[i].spokePool,
                calls[i].helios
            );
        }

        // ---- Option A: single HubPool.multicall(bytes[]) ----
        // Each entry is an encoded relaySpokePoolAdminFunction(chainId, functionData) call.
        console.log("");
        console.log("=== Option A: single HubPool.multicall on %s ===", hubPoolAddress);
        console.log("Calldata array (copy this for multicall):");
        console.log("[");
        for (uint256 i = 0; i < validCallCount; i++) {
            bytes memory hubPoolCalldata = abi.encodeWithSelector(
                IHubPool.relaySpokePoolAdminFunction.selector,
                calls[i].chainId,
                calls[i].functionData
            );
            console.log("  %s%s", vm.toString(hubPoolCalldata), i < validCallCount - 1 ? "," : "");
        }
        console.log("]");

        // ---- Option B: one relaySpokePoolAdminFunction call per chain ----
        console.log("");
        console.log(
            "=== Option B: %d separate HubPool.relaySpokePoolAdminFunction call(s) on %s ===",
            validCallCount,
            hubPoolAddress
        );
        console.log("Signature: relaySpokePoolAdminFunction(uint256 chainId, bytes functionData)");
        for (uint256 i = 0; i < validCallCount; i++) {
            console.log("");
            console.log("Call %d:", i + 1);
            console.log("  chainId:      %d", calls[i].chainId);
            console.log("  functionData: %s", vm.toString(calls[i].functionData));
        }
        console.log("");
        console.log("============================================");
    }

    // ============ Helper Functions ============

    /**
     * @notice Reads a deployed contract address, decoding Tron base58check addresses to their 20-byte EVM form.
     * @dev Parses the raw JSON string directly (DeployedAddresses.getAddress reverts on base58 via vm.readAddress).
     *      Tron's EVM (eth_call via TronGrid) uses the 20-byte address embedded in the base58check encoding.
     */
    function readAddressTronAware(uint256 chainId, string memory contractName) internal view returns (address) {
        string memory jsonData = vm.readFile("broadcast/deployed-addresses.json");
        string memory path = string.concat(
            '.chains["',
            vm.toString(chainId),
            '"].contracts["',
            contractName,
            '"].address'
        );
        if (!vm.keyExists(jsonData, path)) return address(0);

        string memory raw = vm.parseJsonString(jsonData, path);
        bytes memory rawBytes = bytes(raw);
        // EVM addresses are hex ("0x..."); anything else is treated as Tron base58check.
        if (rawBytes.length >= 2 && rawBytes[0] == "0" && rawBytes[1] == "x") {
            return vm.parseAddress(raw);
        }
        return tronBase58ToAddress(rawBytes);
    }

    /// @notice Decodes a Tron base58check address (25 bytes: 0x41 prefix + 20-byte address + 4-byte checksum).
    function tronBase58ToAddress(bytes memory b58) internal pure returns (address) {
        bytes memory decoded = decodeBase58(b58);
        require(decoded.length == 25, "Invalid Tron address length");
        require(uint8(decoded[0]) == 0x41, "Invalid Tron address prefix");
        uint160 addr;
        for (uint256 i = 1; i <= 20; i++) {
            addr = (addr << 8) | uint8(decoded[i]);
        }
        return address(addr);
    }

    /// @notice Big-endian base58 decode (Bitcoin/Tron alphabet).
    function decodeBase58(bytes memory s) internal pure returns (bytes memory) {
        bytes memory digits = new bytes(s.length); // little-endian byte accumulator; decoded len <= input len
        uint256 size = 0;
        for (uint256 i = 0; i < s.length; i++) {
            uint256 carry = base58CharIndex(s[i]);
            for (uint256 j = 0; j < size; j++) {
                carry += uint256(uint8(digits[j])) * 58;
                digits[j] = bytes1(uint8(carry & 0xff));
                carry /= 256;
            }
            while (carry > 0) {
                digits[size++] = bytes1(uint8(carry & 0xff));
                carry /= 256;
            }
        }
        // Each leading '1' in base58 represents a leading zero byte.
        uint256 zeros = 0;
        while (zeros < s.length && s[zeros] == "1") zeros++;

        bytes memory out = new bytes(zeros + size);
        for (uint256 i = 0; i < size; i++) {
            out[zeros + i] = digits[size - 1 - i]; // reverse little-endian -> big-endian
        }
        return out;
    }

    /// @notice Returns the index of a character in the base58 alphabet, reverting on invalid characters.
    function base58CharIndex(bytes1 c) internal pure returns (uint256) {
        bytes memory alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        for (uint256 i = 0; i < alphabet.length; i++) {
            if (alphabet[i] == c) return i;
        }
        revert("Invalid base58 character");
    }

    function parseChainIds(string memory chainsStr) internal pure returns (uint256[] memory) {
        // Count commas to determine array size
        bytes memory chainsBytes = bytes(chainsStr);
        uint256 count = 1;
        for (uint256 i = 0; i < chainsBytes.length; i++) {
            if (chainsBytes[i] == ",") {
                count++;
            }
        }

        uint256[] memory chainIds = new uint256[](count);
        uint256 idx = 0;
        uint256 start = 0;

        for (uint256 i = 0; i <= chainsBytes.length; i++) {
            if (i == chainsBytes.length || chainsBytes[i] == ",") {
                // Extract substring and parse
                bytes memory numBytes = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    numBytes[j - start] = chainsBytes[j];
                }
                chainIds[idx++] = parseUint(string(numBytes));
                start = i + 1;
            }
        }

        return chainIds;
    }

    function parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            // Skip whitespace
            if (c == 0x20) continue;
            require(c >= 48 && c <= 57, "Invalid character in number");
            result = result * 10 + (c - 48);
        }
        return result;
    }
}

// ============ Minimal Interfaces ============

interface IHubPool {
    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) external;
}

interface IUniversalSpokePool {
    function helios() external view returns (address);
    function executeExternalCall(bytes memory message) external;
}

interface ISP1Helios {
    function VKEY_UPDATER_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function heliosProgramVkey() external view returns (bytes32);
    function updateHeliosProgramVkey(bytes32 newHeliosProgramVkey) external;
}
