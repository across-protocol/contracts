// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "../utils/Constants.sol";

/**
 * @title UpdateVkey
 * @notice Generates HubPool.multicall() calldata for updating SP1Helios verification keys across multiple chains.
 * The script queries each chain to verify Helios setup and outputs calldata for the HubPool owner (multisig) to execute.
 * RPC URLs are read from .env using the NODE_URL_<CHAIN_ID> convention (e.g., NODE_URL_56, NODE_URL_143).
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
contract UpdateVkey is Script, Constants {
    // Expected value for VKEY_UPDATER_ROLE to sanity check on-chain value
    bytes32 constant EXPECTED_VKEY_UPDATER_ROLE = 0x07ecc55c8d82c6f82ef86e34d1905e0f2873c085733fa96f8a6e0316b050d174;

    // Struct to hold per-chain call data
    struct ChainCall {
        uint256 chainId;
        address spokePool;
        address helios;
        bytes hubPoolCalldata;
    }

    function run(bytes32 newVkey, string calldata chainsStr) external {
        // Parse chain IDs from argument
        uint256[] memory chainIds = parseChainIds(chainsStr);

        // Read deployed addresses
        string memory deployedAddressesJson = vm.readFile("broadcast/deployed-addresses.json");

        // Get HubPool address (from mainnet)
        address hubPoolAddress = getDeployedAddress(deployedAddressesJson, 1, "HubPool");
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

            // Get SpokePool address for this chain
            address spokePoolAddress = getDeployedAddress(deployedAddressesJson, chainId, "SpokePool");
            if (spokePoolAddress == address(0)) {
                console.log("Skipping chain %d: no SpokePool in deployed-addresses.json", chainId);
                failedChains[failedCount++] = chainId;
                continue;
            }

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
            address heliosAddress;
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

            console.log("Chain %d: building updateHeliosProgramVkey() call", chainId);
            console.log("  SpokePool:", spokePoolAddress);
            console.log("  Helios:", heliosAddress);
            console.log("  Current Vkey:", vm.toString(currentVkey));

            // Build nested calldata
            // 1. Helios.updateHeliosProgramVkey(newVkey)
            bytes memory heliosCalldata = abi.encodeWithSelector(
                ISP1Helios.updateHeliosProgramVkey.selector,
                newVkey
            );

            // 2. SpokePool.executeExternalCall(message) where message = abi.encode(helios, heliosCalldata)
            bytes memory message = abi.encode(heliosAddress, heliosCalldata);
            bytes memory spokePoolCalldata = abi.encodeWithSelector(
                IUniversalSpokePool.executeExternalCall.selector,
                message
            );

            // 3. HubPool.relaySpokePoolAdminFunction(chainId, spokePoolCalldata)
            bytes memory hubPoolCalldata = abi.encodeWithSelector(
                IHubPool.relaySpokePoolAdminFunction.selector,
                chainId,
                spokePoolCalldata
            );

            calls[validCallCount++] = ChainCall({
                chainId: chainId,
                spokePool: spokePoolAddress,
                helios: heliosAddress,
                hubPoolCalldata: hubPoolCalldata
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
            console.log("  - chainId=%d, spokePool=%s, helios=%s", 
                calls[i].chainId, 
                calls[i].spokePool, 
                calls[i].helios
            );
        }

        // Output multicall data
        console.log("");
        console.log("Data to use for HubPool.multicall on %s:", hubPoolAddress);
        console.log("Each entry is an encoded `relaySpokePoolAdminFunction` call.");
        console.log("");
        console.log("Included destination chains:");
        for (uint256 i = 0; i < validCallCount; i++) {
            console.log("  %d", calls[i].chainId);
        }
        console.log("");
        console.log("Calldata array (copy this for multicall):");
        console.log("[");
        for (uint256 i = 0; i < validCallCount; i++) {
            if (i < validCallCount - 1) {
                console.log("  %s,", vm.toString(calls[i].hubPoolCalldata));
            } else {
                console.log("  %s", vm.toString(calls[i].hubPoolCalldata));
            }
        }
        console.log("]");
        console.log("");
        console.log("============================================");
    }

    // ============ Helper Functions ============

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

    function getDeployedAddress(
        string memory json,
        uint256 chainId,
        string memory contractName
    ) internal view returns (address) {
        string memory path = string.concat(
            ".chains.",
            vm.toString(chainId),
            ".contracts.",
            contractName,
            ".address"
        );
        
        try vm.parseJsonAddress(json, path) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
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
