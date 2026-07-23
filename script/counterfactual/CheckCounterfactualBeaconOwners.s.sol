// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CheckUtils } from "./CheckUtils.sol";

// Reports `owner()`/`pendingOwner()` of the live CounterfactualBeacon proxy and `owner()`/
// `directWithdrawer()` of the live AdminWithdrawManager on every config.toml chain, flagging roles
// that still sit with the dev wallet (MNEMONIC account 0, the bootstrap owner) instead of
// config.toml's `ownerAndDirectWithdrawer`, and whether that address actually holds multisig code
// on the chain. Read-only; never broadcasts.
//
// Tron is skipped: forge cannot fork Tron, and its beacon owner is intentionally the deployer key
// (see script/tron/README.md).
//
// How to run:
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualBeaconOwners.s.sol:CheckCounterfactualBeaconOwners \
//     --rpc-url $NODE_URL_1 --gas-limit 100000000000 -vv
contract CheckCounterfactualBeaconOwners is CounterfactualConfig, CheckUtils {
    uint256 constant TRON_CHAIN_ID = 728126428;

    function run() external {
        _loadCounterfactualConfig();
        _loadDeployedAddresses();
        address devWallet = vm.addr(vm.deriveKey(vm.envString("MNEMONIC"), 0));
        console.log("Dev wallet (MNEMONIC account 0): %s", devWallet);

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            if (chainId == GLOBALS_CHAIN_ID) continue;
            if (chainId == TRON_CHAIN_ID) {
                _info("Tron", "skipped: forge cannot fork Tron; beacon owner is intentionally the deployer key");
                continue;
            }
            try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
                vm.selectFork(forkId);
                _checkChain(chainId, devWallet);
            } catch {
                _fail(_getChainName(chainId), "fork", "RPC unreachable or incompatible");
            }
        }
        _printSummary();
    }

    function _checkChain(uint256 chainId, address devWallet) internal {
        string memory name = _getChainName(chainId);
        address expected = config.get(chainId, "ownerAndDirectWithdrawer").toAddress();

        address proxy = _getDeployed("CounterfactualBeacon", chainId);
        if (proxy == address(0) || proxy.code.length == 0) {
            _info(name, "no live beacon proxy on this chain");
        } else {
            _checkRole(name, "beacon.owner", proxy, "owner()", devWallet, expected);
        }

        address awm = _getDeployed("AdminWithdrawManager", chainId);
        if (awm == address(0) || awm.code.length == 0) {
            _info(name, "no live AdminWithdrawManager on this chain");
        } else {
            _checkRole(name, "adminWithdrawManager.owner", awm, "owner()", devWallet, expected);
            _checkRole(name, "adminWithdrawManager.directWithdrawer", awm, "directWithdrawer()", devWallet, expected);
        }
    }

    /// @dev Classifies who holds `sig` on `target`: the dev wallet → [REVIEW] (with any pending
    ///      Ownable2Step transfer); config.toml's `ownerAndDirectWithdrawer` → [PASS] when the address
    ///      holds contract code on this chain (a multisig that was never deployed here would be a bare
    ///      key at best), [REVIEW] when it doesn't; anything else → [FAIL].
    function _checkRole(
        string memory name,
        string memory role,
        address target,
        string memory sig,
        address devWallet,
        address expected
    ) internal {
        (bool ok, bytes32 w) = _tryReadWord(target, abi.encodeWithSignature(sig));
        if (!ok) {
            _fail(name, string.concat(role, " (", sig, ")"), "unreadable");
            return;
        }
        address actual = address(uint160(uint256(w)));
        if (actual == devWallet) {
            (, bytes32 pw) = _tryReadWord(target, abi.encodeWithSignature("pendingOwner()"));
            address pending = address(uint160(uint256(pw)));
            _reviewNote(
                name,
                string.concat(
                    role,
                    " is STILL THE DEV WALLET",
                    pending == address(0)
                        ? " (no pending transfer)"
                        : string.concat(" (transfer pending to ", vm.toString(pending), ")")
                )
            );
        } else if (actual != expected) {
            _fail(name, role, string.concat("unexpected: ", vm.toString(actual)));
        } else if (expected.code.length == 0) {
            _reviewNote(
                name,
                string.concat(role, " = ownerAndDirectWithdrawer but the address holds NO CODE on this chain")
            );
        } else {
            _pass(
                name,
                role,
                string.concat(vm.toString(actual), " (= ownerAndDirectWithdrawer, multisig code present)")
            );
        }
    }
}
