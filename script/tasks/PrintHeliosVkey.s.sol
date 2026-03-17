// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { DeployedAddresses } from "../utils/DeployedAddresses.sol";

/**
 * @title PrintHeliosVkey
 * @notice Prints the active SP1Helios program vkey for a given chain.
 *
 * Example:
 *   forge script script/tasks/PrintHeliosVkey.s.sol:PrintHeliosVkey \
 *     --sig "run(uint256)" 480 -vvv
 *
 * Requires NODE_URL_<CHAIN_ID> env var for the target chain's RPC.
 */
contract PrintHeliosVkey is Script, DeployedAddresses {
    function run(uint256 chainId) external {
        // Resolve deployed addresses.
        address spokePool = getAddress(chainId, "SpokePool");
        require(spokePool != address(0), "SpokePool not found for chain");

        // Fork to target chain.
        string memory rpcUrl = vm.envString(string.concat("NODE_URL_", vm.toString(chainId)));
        vm.createSelectFork(rpcUrl);

        // Read Helios address from SpokePool.
        address helios = IUniversalSpokePool(spokePool).helios();
        require(helios != address(0), "Helios address is zero");

        // Read vkey.
        bytes32 vkey = ISP1Helios(helios).heliosProgramVkey();

        console.log("Chain ID:", chainId);
        console.log("SpokePool:", spokePool);
        console.log("Helios:", helios);
        console.log("Active Vkey:", vm.toString(vkey));
    }
}

interface IUniversalSpokePool {
    function helios() external view returns (address);
}

interface ISP1Helios {
    function heliosProgramVkey() external view returns (bytes32);
}
