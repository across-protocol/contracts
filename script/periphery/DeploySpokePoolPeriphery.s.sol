// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { StdConstants } from "forge-std/StdConstants.sol";
import { SpokePoolPeriphery, SwapProxy } from "../../contracts/periphery/SpokePoolPeriphery.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x", ETHERSCAN_API_KEY="x", and a NODE_URL_<chainId>
//    entry for every target chain (e.g. NODE_URL_10 for Optimism), matching the repo-wide convention.
// 2. Simulate deployment to all chains with a single command (--rpc-url only sets the starting context;
//    the script forks every target chain itself):
//    forge script script/periphery/DeploySpokePoolPeriphery.s.sol:DeploySpokePoolPeriphery --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode, then deploy by adding --broadcast --slow --verify flags.
// 4. To deploy to specific chains only, add: --sig "runOn(string)" "1,10,42161"
//
// run() targets every non-testnet chain in broadcast/deployed-addresses.json that has a SpokePool, skipping
// non-EVM chains (SVM/TVM), deprecated chains (DeploymentUtils.isDeprecatedChain), and chains missing a
// permit2 entry, NODE_URL, or the deterministic CREATE2 factory. ZK-stack chains with the EVM interpreter
// (e.g. zkSync) deploy through the CREATE2 factory like any other chain. Deployments use CREATE2 with a fixed
// salt, so re-runs skip already-deployed chains, and addresses match across chains that share a permit2
// address (zkSync's permit2 differs, so its periphery address does too).
//
// Forge logs broadcasts under the entrypoint's name: run.json / run-latest.json for run(), runOn.json /
// runOn-latest.json for runOn(string). Run `yarn extract-addresses` after every broadcast: it reads the runOn
// logs (gitignored, no git add needed), skips chains whose transactions never landed, and materializes each
// chain's deployment into broadcast/<Script>.s.sol/<chainId>/run-latest.json. Commit those along with
// deployed-addresses.*: forge overwrites the runOn logs on every rerun, so the per-chain files are the record.
abstract contract MultichainPeripheryDeployer is DeploymentUtils {
    /// @dev Deploys to the currently selected fork; called with an active broadcast.
    function _deploy(address permit2) internal virtual;

    /// @notice Deploys to every supported mainnet chain (see chain selection notes above).
    function run() external {
        uint256[] memory chainIds = getChainIds();
        for (uint256 i = 0; i < chainIds.length; i++) {
            _runOn(chainIds[i]);
        }
    }

    /// @notice Deploys to a comma-separated list of chain IDs, e.g. --sig "runOn(string)" "1,10,42161".
    function runOn(string memory chains) external {
        string[] memory chainIds = vm.split(chains, ",");
        for (uint256 i = 0; i < chainIds.length; i++) {
            _runOn(vm.parseUint(chainIds[i]));
        }
    }

    function _runOn(uint256 chainId) internal {
        console.log("");
        console.log("=== Chain %s ===", chainId);
        string memory skipReason = _skipReason(chainId);
        if (bytes(skipReason).length > 0) {
            console.log("Skipping: %s", skipReason);
            return;
        }

        try vm.createFork(vm.envString(string.concat("NODE_URL_", vm.toString(chainId)))) returns (uint256 forkId) {
            vm.selectFork(forkId);
        } catch {
            console.log("Skipping: RPC unreachable");
            return;
        }
        if (StdConstants.CREATE2_FACTORY.code.length == 0) {
            console.log("Skipping: CREATE2 factory not deployed on this chain");
            return;
        }

        vm.startBroadcast(vm.deriveKey(vm.envString("MNEMONIC"), 0));
        _deploy(getPermit2(chainId));
        vm.stopBroadcast();
    }

    /// @dev Returns a non-empty reason if the chain cannot be deployed to from this script.
    function _skipReason(uint256 chainId) private view returns (string memory) {
        string memory chainIdStr = vm.toString(chainId);
        if (!vm.keyExists(file, string.concat(".PUBLIC_NETWORKS.", chainIdStr, ".family")))
            return "unknown chain family";
        bytes32 family = keccak256(bytes(getChainFamily(chainId)));
        if (family == keccak256("SVM") || family == keccak256("TVM")) return "non-EVM chain";
        if (isTestnet(chainId)) return "testnet";
        if (isDeprecatedChain(chainId)) return "chain no longer supported";
        if (!hasAddress(chainId, "SpokePool")) return "no SpokePool deployed";
        if (!vm.keyExists(file, string.concat(".L2_ADDRESS_MAP.", chainIdStr, ".permit2")))
            return "no permit2 entry in constants.json";
        if (bytes(vm.envOr(string.concat("NODE_URL_", chainIdStr), string(""))).length == 0)
            return string.concat("NODE_URL_", chainIdStr, " not set");
        return "";
    }
}

contract DeploySpokePoolPeriphery is MultichainPeripheryDeployer {
    function _deploy(address permit2) internal override {
        address multicall3 = getMulticall3();
        address periphery = _deployCreate2(
            bytes32(uint256(0x1236)),
            abi.encodePacked(type(SpokePoolPeriphery).creationCode, abi.encode(permit2, multicall3))
        );
        console.log("Permit2:", permit2);
        console.log("Multicall3:", multicall3);
        console.log("Spoke pool periphery deployed to:", periphery);
    }
}

contract DeploySwapProxy is MultichainPeripheryDeployer {
    function _deploy(address permit2) internal override {
        address swapProxy = _deployCreate2(
            bytes32(uint256(0x1235)),
            abi.encodePacked(type(SwapProxy).creationCode, abi.encode(permit2))
        );
        console.log("Permit2:", permit2);
        console.log("Swap proxy deployed to:", swapProxy);
    }
}
