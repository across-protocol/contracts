// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { Variable, TypeKind } from "forge-std/LibVariable.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CheckUtils } from "./CheckUtils.sol";

// Reports raw ownership state of the live counterfactual admin surface on every config.toml chain:
// `owner()`/`pendingOwner()` of each deployed CounterfactualBeacon proxy and `owner()`/
// `directWithdrawer()` of each deployed AdminWithdrawManager. Read-only on-chain; results go to the
// console AND a timestamped CSV in the repo root (counterfactual-ownership-<unix>.csv) with columns
//   chainId,chain,contract,field,value,note
// where note labels known addresses: dev-wallet (MNEMONIC account 0), multisig (this chain's
// config.toml ownerAndDirectWithdrawer) or zero. Unlike CheckCounterfactualBeaconOwners (PASS/FAIL
// classification, no file output), this script never fails on findings — it is a snapshot to file.
//
// Tron is skipped (forge cannot fork Tron; its beacon owner is intentionally the deployer key, see
// script/tron/README.md).
//
// How to run (--gas-limit: one EVM frame spans ~24 forks of JSON-cheatcode work, which outgrows the
// default gas limit):
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/ReportCounterfactualOwnership.s.sol:ReportCounterfactualOwnership \
//     --rpc-url $NODE_URL_1 --gas-limit 100000000000 -vv
contract ReportCounterfactualOwnership is CounterfactualConfig, CheckUtils {
    uint256 constant TRON_CHAIN_ID = 728126428;

    string reportPath;
    address devWallet;

    function run() external {
        _loadCounterfactualConfig();
        _loadDeployedAddresses();
        devWallet = vm.addr(vm.deriveKey(vm.envString("MNEMONIC"), 0));

        reportPath = string.concat("counterfactual-ownership-", vm.toString(vm.unixTime() / 1000), ".csv");
        vm.writeFile(reportPath, "chainId,chain,contract,field,value,note\n");
        console.log("Dev wallet (MNEMONIC account 0): %s", devWallet);

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            // Skip the synthetic `[0]` globals section in config.toml (holds the deploy salt, not a real chain).
            if (chainId == GLOBALS_CHAIN_ID) continue;
            if (chainId == TRON_CHAIN_ID) {
                _row(
                    chainId,
                    "-",
                    "status",
                    "skipped: forge cannot fork Tron (beacon owner is the deployer key by design)"
                );
                continue;
            }
            try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
                vm.selectFork(forkId);
                _reportChain(chainId);
            } catch {
                _row(chainId, "-", "status", "RPC unreachable or incompatible");
            }
        }

        console.log("");
        console.log("Report written to %s", reportPath);
    }

    function _reportChain(uint256 chainId) internal {
        address expected = _expectedOwner(chainId);

        address beacon = _getDeployed("CounterfactualBeacon", chainId);
        if (beacon == address(0) || beacon.code.length == 0) {
            _row(chainId, "CounterfactualBeacon", "status", "not-deployed");
        } else {
            _reportField(chainId, "CounterfactualBeacon", beacon, "owner()", expected);
            _reportField(chainId, "CounterfactualBeacon", beacon, "pendingOwner()", expected);
        }

        address awm = _getDeployed("AdminWithdrawManager", chainId);
        if (awm == address(0) || awm.code.length == 0) {
            _row(chainId, "AdminWithdrawManager", "status", "not-deployed");
        } else {
            _reportField(chainId, "AdminWithdrawManager", awm, "owner()", expected);
            _reportField(chainId, "AdminWithdrawManager", awm, "directWithdrawer()", expected);
        }
    }

    /// @dev This chain's config.toml `ownerAndDirectWithdrawer`, or address(0) when unset (labels only —
    ///      never asserted here).
    function _expectedOwner(uint256 chainId) internal returns (address) {
        Variable memory v = config.get(chainId, "ownerAndDirectWithdrawer");
        return v.ty.kind == TypeKind.Address ? v.toAddress() : address(0);
    }

    /// @dev Guarded single-word read (see CheckUtils: era-VM/exotic-runtime accounts make direct calls
    ///      unsafe on some forks); records "unreadable" instead of aborting the run.
    function _reportField(
        uint256 chainId,
        string memory contract_,
        address target,
        string memory sig,
        address expected
    ) internal {
        (bool ok, bytes32 word) = _tryReadWord(target, abi.encodeWithSignature(sig));
        if (!ok) {
            _row(chainId, contract_, sig, "unreadable");
            return;
        }
        address value = address(uint160(uint256(word)));
        _rowWithNote(chainId, contract_, sig, vm.toString(value), _label(value, expected));
    }

    function _label(address value, address expected) internal view returns (string memory) {
        if (value == address(0)) return "zero";
        if (value == devWallet) return "dev-wallet";
        if (value == expected) return "multisig (ownerAndDirectWithdrawer)";
        return "UNRECOGNIZED";
    }

    function _row(uint256 chainId, string memory contract_, string memory field, string memory value) internal {
        _rowWithNote(chainId, contract_, field, value, "");
    }

    function _rowWithNote(
        uint256 chainId,
        string memory contract_,
        string memory field,
        string memory value,
        string memory note
    ) internal {
        string memory line = string.concat(
            vm.toString(chainId),
            ",",
            _getChainName(chainId),
            ",",
            contract_,
            ",",
            field,
            ",",
            value,
            ",",
            note
        );
        console.log(line);
        vm.writeLine(reportPath, line);
    }
}
