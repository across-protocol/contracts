#!/usr/bin/env ts-node
/**
 * Verifies the deployed Tron counterfactual beacon stack on TronScan — the counterpart of
 * CheckCounterfactualBeaconImpls/Etherscan `--verify` on the EVM side.
 *
 * All mechanics live in `../verify.ts`, copied verbatim from the V5 repo (`script/tron/verify.ts`) since it
 * is repo-agnostic: `REPO_ROOT` is derived from `__dirname`, and its only local import (`resolveChainId`,
 * `TRON_MAINNET_CHAIN_ID`) is satisfied by this repo's `script/tron/deploy.ts`. For every entry with a
 * broadcast artifact (written by the deploy scripts under
 * `broadcast/TronDeploy<broadcast>.s.sol/<chainId>/run-latest.json`) it recovers the deployed address and
 * constructor args from the recorded initcode, checks that initcode against the current `out-tron/` artifact,
 * flattens the source, and POSTs to TronScan with settings mirroring the `tron` Foundry profile.
 * Already-verified contracts, and contracts with no broadcast artifact, are skipped.
 *
 * Note the two distinct names per entry. `broadcast` is the on-chain `CreateSmartContract` name, which a
 * deploy script may shorten via `contractNameOverride` — the beacon proxy is deployed as
 * "CounterfactualBeaconProxy" but is really an `ERC1967Proxy`, which is what TronScan compiles and matches.
 *
 * Prerequisites: `bin/solc-tron` and an `out-tron/` built from the DEPLOYED sources (`FOUNDRY_PROFILE=tron
 * forge build`). `verify.ts` refuses to submit when the local bytecode is not a prefix of the deployed
 * initcode, which is what catches a rebuild that drifted from what is on-chain.
 *
 * Usage:
 *   yarn tron-verify-counterfactual-stack [--testnet] [--dry-run] [names...]
 *
 * `names` are broadcast names, e.g. `CounterfactualDeposit`.
 */

import { LICENSE_BUSL, LICENSE_MIT, runVerification, StackContract } from "../verify";

/**
 * Deploy-order roster, mirroring tron-deploy-counterfactual-beacon-impl → tron-deploy-counterfactual-beacon
 * → tron-deploy-admin-withdraw-manager. `CounterfactualBeaconBootstrap` is absent because the Tron flow has
 * no bootstrap step: it exists only to give the proxy one CREATE2 address on every chain, which Tron's 0x41
 * CREATE2 prefix makes unattainable, so the proxy is deployed directly over the real implementation.
 */
const COUNTERFACTUAL_STACK: StackContract[] = [
  {
    broadcast: "CounterfactualBeacon",
    contract: "CounterfactualBeacon",
    source: "contracts/periphery/counterfactual/CounterfactualBeacon.sol",
    license: LICENSE_BUSL,
  },
  {
    // Deployed under a `contractNameOverride`; the compiled contract is OpenZeppelin's ERC1967Proxy.
    broadcast: "CounterfactualBeaconProxy",
    contract: "ERC1967Proxy",
    source: "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol",
    license: LICENSE_MIT,
  },
  {
    broadcast: "CounterfactualDeposit",
    contract: "CounterfactualDeposit",
    source: "contracts/periphery/counterfactual/CounterfactualDeposit.sol",
    license: LICENSE_BUSL,
  },
  {
    broadcast: "AdminWithdrawManager",
    contract: "AdminWithdrawManager",
    source: "contracts/periphery/counterfactual/AdminWithdrawManager.sol",
    license: LICENSE_BUSL,
  },
];

runVerification(COUNTERFACTUAL_STACK, "counterfactual beacon stack").catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
