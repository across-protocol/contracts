// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositSpokePool } from "../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { AdminWithdrawManager } from "../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";

// Verifies counterfactual contract deployments across all configured chains.
//
// Auto-checks values derivable from constants.json and deployed-addresses.json (spokePool,
// wrappedNativeToken, cctpDomain, srcPeriphery, oftEid, etc.) and surfaces values that require
// manual human review (signer, owner, directWithdrawer).
//
// Owner/directWithdrawer are cross-referenced against both config.toml and
// script/mintburn/prod-readiness-multisigs.json for an independent second opinion.
//
// Output uses structured prefixes for easy grep:
//   [PASS]   - Auto-check passed
//   [FAIL]   - Auto-check failed (investigate!)
//   [REVIEW] - Manual review needed (always printed, never silently passed)
//   [INFO]   - Informational
//
// How to run:
//   source .env
//   FOUNDRY_PROFILE=counterfactual forge script \
//     script/counterfactual/CheckCounterfactualDeployments.s.sol:CheckCounterfactualDeployments \
//     --rpc-url $NODE_URL_1 --ffi -vvvv
contract CheckCounterfactualDeployments is Script, Test, CounterfactualConfig {
    string constant MULTISIGS_PATH = "script/mintburn/prod-readiness-multisigs.json";

    string multisigsJson;
    string deployedAddressesJson;

    uint256 totalPass;
    uint256 totalFail;
    uint256 totalReview;

    function run() external {
        _loadConfig(CONFIG_PATH, false);
        multisigsJson = vm.readFile(MULTISIGS_PATH);
        deployedAddressesJson = vm.readFile("broadcast/deployed-addresses.json");

        uint256[] memory chains = config.getChainIds();
        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            try vm.createFork(config.getRpcUrl(chainId)) returns (uint256 forkId) {
                vm.selectFork(forkId);
                _checkChain(chainId);
            } catch {
                _fail(string.concat("Chain ", vm.toString(chainId)), "fork", "RPC unreachable or incompatible");
            }
        }

        console.log("============================================");
        console.log("SUMMARY: %s passed, %s failed, %s manual review", totalPass, totalFail, totalReview);
        console.log("============================================");

        require(totalFail == 0, "Some auto-checks FAILED");
    }

    // --- Per-chain entry ---

    function _checkChain(uint256 chainId) internal {
        string memory name = _getChainName(chainId);
        console.log("");
        console.log("## %s (Chain %s)", name, chainId);

        _checkBytecodeContracts(chainId);
        _checkSpokePoolContract(chainId);
        _checkCctpContract(chainId);
        _checkOftContract(chainId);
        _checkAdminWithdrawManager(chainId);
    }

    // --- Bytecode-only contracts ---

    function _checkBytecodeContracts(uint256 chainId) internal {
        string[3] memory names = [
            string("CounterfactualDeposit"),
            "CounterfactualDepositFactory",
            "WithdrawImplementation"
        ];
        for (uint256 i = 0; i < 3; i++) {
            address addr = _getDeployed(names[i], chainId);
            if (addr == address(0)) {
                _fail(names[i], "address", "not in deployed-addresses.json");
            } else if (addr.code.length == 0) {
                _fail(names[i], "bytecode", "no code on-chain");
            } else {
                _pass(names[i], "bytecode", "deployed");
            }
        }
    }

    // --- CounterfactualDepositSpokePool ---

    function _checkSpokePoolContract(uint256 chainId) internal {
        address addr = _getDeployed("CounterfactualDepositSpokePool", chainId);
        if (addr == address(0)) {
            _fail("CounterfactualDepositSpokePool", "address", "not in deployed-addresses.json");
            return;
        }
        if (addr.code.length == 0) {
            _fail("CounterfactualDepositSpokePool", "bytecode", "no code on-chain");
            return;
        }

        CounterfactualDepositSpokePool sp = CounterfactualDepositSpokePool(addr);

        // Auto-check: spokePool vs deployed-addresses.json
        address expectedSpokePool = _getDeployed("SpokePool", chainId);
        if (expectedSpokePool != address(0)) {
            _assertAddrEq("CounterfactualDepositSpokePool", "spokePool", sp.spokePool(), expectedSpokePool);
        } else {
            _review(
                "CounterfactualDepositSpokePool",
                "spokePool",
                sp.spokePool(),
                address(0),
                "deployed-addresses.json (no entry)"
            );
        }

        // Auto-check: wrappedNativeToken vs constants.json
        {
            string memory wntKey = string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(chainId));
            if (vm.keyExists(file, wntKey)) {
                _assertAddrEq(
                    "CounterfactualDepositSpokePool",
                    "wrappedNativeToken",
                    sp.wrappedNativeToken(),
                    vm.parseJsonAddress(file, wntKey)
                );
            } else {
                _review(
                    "CounterfactualDepositSpokePool",
                    "wrappedNativeToken",
                    sp.wrappedNativeToken(),
                    address(0),
                    "constants.json (no entry)"
                );
            }
        }

        // Manual review: signer (no second source)
        address configSigner = config.get("signer").toAddress();
        _review("CounterfactualDepositSpokePool", "signer", sp.signer(), configSigner, "config.toml");
    }

    // --- CounterfactualDepositCCTP ---

    function _checkCctpContract(uint256 chainId) internal {
        address addr = _getDeployed("CounterfactualDepositCCTP", chainId);
        if (addr == address(0)) {
            if (hasCctpDomain(chainId) && _getCctpPeriphery(chainId) != address(0)) {
                _fail("CounterfactualDepositCCTP", "deployment", "CCTP supported + periphery exists, but not deployed");
            } else {
                _info("CounterfactualDepositCCTP", "skipped (not applicable on this chain)");
            }
            return;
        }
        if (addr.code.length == 0) {
            _fail("CounterfactualDepositCCTP", "bytecode", "no code on-chain");
            return;
        }

        CounterfactualDepositCCTP cctp = CounterfactualDepositCCTP(addr);

        // Auto-check: srcPeriphery vs deployed-addresses.json
        _assertAddrEq("CounterfactualDepositCCTP", "srcPeriphery", cctp.srcPeriphery(), _getCctpPeriphery(chainId));

        // Auto-check: sourceDomain vs constants.json
        _assertUintEq(
            "CounterfactualDepositCCTP",
            "sourceDomain",
            uint256(cctp.sourceDomain()),
            uint256(getCircleDomainId(chainId))
        );
    }

    // --- CounterfactualDepositOFT ---

    function _checkOftContract(uint256 chainId) internal {
        address addr = _getDeployed("CounterfactualDepositOFT", chainId);
        if (addr == address(0)) {
            if (hasOftEid(chainId) && _getOftPeriphery(chainId) != address(0)) {
                _fail("CounterfactualDepositOFT", "deployment", "OFT supported + periphery exists, but not deployed");
            } else {
                _info("CounterfactualDepositOFT", "skipped (not applicable on this chain)");
            }
            return;
        }
        if (addr.code.length == 0) {
            _fail("CounterfactualDepositOFT", "bytecode", "no code on-chain");
            return;
        }

        CounterfactualDepositOFT oft = CounterfactualDepositOFT(addr);

        // Auto-check: oftSrcPeriphery vs deployed-addresses.json
        _assertAddrEq("CounterfactualDepositOFT", "oftSrcPeriphery", oft.oftSrcPeriphery(), _getOftPeriphery(chainId));

        // Auto-check: srcEid vs constants.json
        _assertUintEq("CounterfactualDepositOFT", "srcEid", uint256(oft.srcEid()), getOftEid(chainId));
    }

    // --- AdminWithdrawManager ---

    function _checkAdminWithdrawManager(uint256 chainId) internal {
        address addr = _getDeployed("AdminWithdrawManager", chainId);
        if (addr == address(0)) {
            _fail("AdminWithdrawManager", "address", "not in deployed-addresses.json");
            return;
        }
        if (addr.code.length == 0) {
            _fail("AdminWithdrawManager", "bytecode", "no code on-chain");
            return;
        }

        AdminWithdrawManager awm = AdminWithdrawManager(addr);

        address configOwner = config.get("ownerAndDirectWithdrawer").toAddress();
        address configSigner = config.get("signer").toAddress();
        address multisig = _getMultisig(chainId);

        // Manual review: owner — cross-reference config.toml AND multisigs.json
        _reviewWithMultisig("AdminWithdrawManager", "owner", awm.owner(), configOwner, multisig);

        // Manual review: directWithdrawer — cross-reference config.toml AND multisigs.json
        _reviewWithMultisig("AdminWithdrawManager", "directWithdrawer", awm.directWithdrawer(), configOwner, multisig);

        // Manual review: signer (no second source)
        _review("AdminWithdrawManager", "signer", awm.signer(), configSigner, "config.toml");
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

    // --- Cached CCTP/OFT periphery lookups ---

    function _getCctpPeriphery(uint256 chainId) internal view returns (address) {
        address addr = _getDeployed("SponsoredCCTPSrcPeriphery", chainId);
        if (addr == address(0)) addr = _getDeployed("SponsoredCctpSrcPeriphery", chainId);
        return addr;
    }

    function _getOftPeriphery(uint256 chainId) internal view returns (address) {
        return _getDeployed("SponsoredOFTSrcPeriphery", chainId);
    }

    // --- Multisig lookup ---

    function _getMultisig(uint256 chainId) internal view returns (address) {
        string memory path = string.concat(".", vm.toString(chainId));
        if (vm.keyExists(multisigsJson, path)) {
            return vm.parseJsonAddress(multisigsJson, path);
        }
        return vm.parseJsonAddress(multisigsJson, ".fallbackEOA");
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

    function _review(
        string memory contract_,
        string memory field,
        address actual,
        address configValue,
        string memory source
    ) internal {
        string memory tag = actual == configValue
            ? string.concat("matches ", source)
            : string.concat("MISMATCH vs ", source, ": ", vm.toString(configValue));
        console.log(string.concat("[REVIEW] ", contract_, ".", field, " = ", vm.toString(actual), " (", tag, ")"));
        totalReview++;
    }

    function _reviewWithMultisig(
        string memory contract_,
        string memory field,
        address actual,
        address configValue,
        address multisig
    ) internal {
        console.log("[REVIEW] %s.%s = %s", contract_, field, vm.toString(actual));
        console.log(
            string.concat(
                "           config.toml: ",
                vm.toString(configValue),
                actual == configValue ? unicode" ✓" : " MISMATCH"
            )
        );
        console.log(
            string.concat(
                "           multisigs.json: ",
                vm.toString(multisig),
                actual == multisig ? unicode" ✓" : " MISMATCH"
            )
        );
        totalReview++;
    }
}
