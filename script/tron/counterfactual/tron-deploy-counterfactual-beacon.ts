#!/usr/bin/env ts-node
/**
 * Deploys the CounterfactualBeacon proxy stack to Tron and wires it up:
 *   1. ERC1967Proxy over the chain-specific CounterfactualBeacon impl (from
 *      tron-deploy-counterfactual-beacon-impl's broadcast, or an explicit arg), initialized with
 *      `initialize(deployer, address(0), bytes32(0))` — the lazy-init path CounterfactualBeaconBase
 *      documents (beacon → dispatcher → setImplementation).
 *   2. The CounterfactualDeposit dispatcher bound to the proxy.
 *   3. `setImplementation(dispatcher)` on the proxy so every counterfactual clone resolves the dispatcher.
 *
 * Unlike the EVM flow (DeployCounterfactualBeacon.s.sol) there is NO bootstrap step: the bootstrap
 * exists only to give the proxy one CREATE2 address on every chain, and Tron's 0x41 CREATE2 prefix (and
 * TronWeb's plain-CREATE deploys) make cross-chain address parity impossible — so the proxy is deployed
 * directly over the real impl. Consequently deploys here are NOT idempotent: re-running deploys a fresh
 * stack rather than completing an interrupted one.
 *
 * The deployer stays the beacon owner (Ownable2Step); transfer ownership out of band if needed.
 *
 * Options:
 *   --testnet  — deploy to Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn tron-deploy-counterfactual-beacon [<beaconImpl>] [--testnet]
 *     beaconImpl — optional CounterfactualBeacon impl address (Tron Base58Check, T...); defaults to the
 *                  most recent tron-deploy-counterfactual-beacon-impl broadcast for this chain
 */

import "dotenv/config";
import * as path from "path";
import { TronWeb } from "tronweb";
import {
  deployContract,
  callContract,
  encodeArgs,
  tronToEvmAddress,
  validateTronAddress,
  resolveChainId,
  readBroadcastAddress,
  getDeployerAddress,
} from "../deploy";

const REPO_ROOT = path.resolve(__dirname, "../../..");
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ZERO_BYTES32 = "0x" + "0".repeat(64);

async function main(): Promise<void> {
  const chainId = resolveChainId();
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));

  const beaconImpl = args[0] ?? readBroadcastAddress("CounterfactualBeacon", chainId);
  if (!beaconImpl) {
    console.log(
      "Error: no CounterfactualBeacon impl broadcast for this chain and no impl address passed.\n" +
        "Run tron-deploy-counterfactual-beacon-impl first, or pass the impl address explicitly."
    );
    process.exit(1);
  }
  validateTronAddress(beaconImpl, "beaconImpl");

  const deployer = getDeployerAddress(chainId);

  console.log("=== CounterfactualBeacon proxy stack deployment ===");
  console.log(`Chain ID:    ${chainId}`);
  console.log(`Beacon impl: ${beaconImpl}`);
  console.log(`Deployer:    ${deployer} (stays beacon owner — transfer out of band if needed)`);

  // 1. ERC1967Proxy(impl, initialize(deployer, 0, 0)) — lazy init; dispatcher is wired in step 3.
  const initCalldata =
    TronWeb.sha3("initialize(address,address,bytes32)", true).slice(0, 10) +
    encodeArgs(["address", "address", "bytes32"], [tronToEvmAddress(deployer), ZERO_ADDRESS, ZERO_BYTES32]).slice(2);
  const proxy = await deployContract({
    chainId,
    artifactPath: path.resolve(REPO_ROOT, "out-tron/ERC1967Proxy.sol/ERC1967Proxy.json"),
    encodedArgs: encodeArgs(["address", "bytes"], [tronToEvmAddress(beaconImpl), initCalldata]),
    contractNameOverride: "CounterfactualBeaconProxy",
  });

  // 2. The dispatcher every counterfactual clone delegatecalls, bound to the proxy (its immutable BEACON —
  //    setImplementation validates this binding).
  const dispatcher = await deployContract({
    chainId,
    artifactPath: path.resolve(REPO_ROOT, "out-tron/CounterfactualDeposit.sol/CounterfactualDeposit.json"),
    encodedArgs: encodeArgs(["address"], [tronToEvmAddress(proxy.address)]),
  });

  // 3. Point the beacon at the dispatcher (onlyOwner — the deployer, from initialize above).
  await callContract({
    chainId,
    contract: proxy.address,
    functionSelector: "setImplementation(address)",
    parameters: [{ type: "address", value: dispatcher.address }],
  });

  console.log("=== Beacon stack deployed ===");
  console.log(`Beacon proxy: ${proxy.address}`);
  console.log(`Dispatcher:   ${dispatcher.address}`);
  console.log("Next: deploy the factory bound to this proxy (tron-deploy-counterfactual-factory <proxy>).");
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
