#!/usr/bin/env ts-node
/**
 * Deploys a counterfactual deposit clone for testing.
 *
 * Builds a merkle tree with a single leaf for CounterfactualDepositSpokePool,
 * then deploys a clone via the factory. Outputs the clone address and all parameters
 * needed by the execute script.
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key)
 *   NODE_URL_728126428    — Tron mainnet full node URL
 *   NODE_URL_3448148188   — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT        — optional, in sun (default: 100000000 = 100 TRX)
 *
 * Options:
 *   --testnet  — use Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn test-deploy-clone <factory> <counterfactual-deposit-impl> <spokepool-deposit-impl> <input-token> [--testnet]
 *
 * Addresses in Tron Base58Check format (T...).
 */

import "dotenv/config";
import { TronWeb } from "tronweb";
import { utils as ethersUtils } from "ethers";
import {
  tronToEvmAddress,
  resolveChainId,
  TRON_MAINNET_CHAIN_ID,
  TRON_TESTNET_CHAIN_ID,
  validateTronAddresses,
} from "../deploy";

const POLL_INTERVAL_MS = 3000;
const MAX_POLL_ATTEMPTS = 40;

const TRONSCAN_URLS: Record<string, string> = {
  [TRON_MAINNET_CHAIN_ID]: "https://tronscan.org",
  [TRON_TESTNET_CHAIN_ID]: "https://nile.tronscan.org",
};

const DESTINATION_CHAIN_ID = 1;

async function main(): Promise<void> {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("-"));
  const factoryAddress = args[0];
  const counterfactualDepositImpl = args[1];
  const spokePoolDepositImpl = args[2];
  const inputTokenAddress = args[3];

  if (!factoryAddress || !counterfactualDepositImpl || !spokePoolDepositImpl || !inputTokenAddress) {
    console.log(
      "Usage: yarn test-deploy-clone <factory> <counterfactual-deposit-impl> <spokepool-deposit-impl> <input-token> [--testnet]"
    );
    process.exit(1);
  }

  validateTronAddresses({
    factory: factoryAddress,
    "counterfactual-deposit-impl": counterfactualDepositImpl,
    "spokepool-deposit-impl": spokePoolDepositImpl,
    "input-token": inputTokenAddress,
  });

  const chainId = resolveChainId();
  const feeLimit = parseInt(process.env.TRON_FEE_LIMIT || "100000000", 10);

  const mnemonic = process.env.MNEMONIC;
  const fullNode = process.env[`NODE_URL_${chainId}`];
  if (!mnemonic) {
    console.log("Error: MNEMONIC env var is required.");
    process.exit(1);
  }
  if (!fullNode) {
    console.log(`Error: NODE_URL_${chainId} env var is required.`);
    process.exit(1);
  }

  const tronWeb = new TronWeb({ fullHost: fullNode });
  const { ethersHDNodeWallet, Mnemonic } = tronWeb.utils.ethersUtils;
  const mnemonicObj = Mnemonic.fromPhrase(mnemonic);
  const wallet = ethersHDNodeWallet.fromMnemonic(mnemonicObj, "m/44'/60'/0'/0/0");
  tronWeb.setPrivateKey(wallet.privateKey.slice(2));

  const signerEvmAddress = tronToEvmAddress(tronWeb.address.fromPrivateKey(wallet.privateKey.slice(2)) as string);
  const factoryTronHex = TronWeb.address.toHex(factoryAddress);
  const counterfactualDepositImplEvm = tronToEvmAddress(counterfactualDepositImpl);
  const spokePoolDepositImplEvm = tronToEvmAddress(spokePoolDepositImpl);
  const inputTokenEvmAddress = tronToEvmAddress(inputTokenAddress);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  console.log("=== Deploy Counterfactual Clone ===");
  console.log(`Chain ID:                    ${chainId}`);
  console.log(`Factory:                     ${factoryAddress}`);
  console.log(`CounterfactualDeposit impl:  ${counterfactualDepositImpl} (${counterfactualDepositImplEvm})`);
  console.log(`SpokePoolDeposit impl:       ${spokePoolDepositImpl} (${spokePoolDepositImplEvm})`);
  console.log(`Input token:                 ${inputTokenAddress} (${inputTokenEvmAddress})`);
  console.log(`Signer/recipient:            ${signerEvmAddress}`);

  // --- Build merkle tree ---
  // SpokePoolDepositParams struct encoded as a tuple
  const recipientBytes32 = "0x" + signerEvmAddress.slice(2).padStart(64, "0");
  const inputTokenBytes32 = "0x" + inputTokenEvmAddress.slice(2).padStart(64, "0");
  const outputTokenBytes32 = inputTokenBytes32;

  const paramsEncoded = tronWeb.utils.abi.encodeParams(
    ["(uint256,bytes32,bytes32,bytes32,bytes,uint256,uint256,uint256,uint256)"],
    [
      [
        DESTINATION_CHAIN_ID,
        inputTokenBytes32,
        outputTokenBytes32,
        recipientBytes32,
        "0x", // empty message
        "1000000000000000000", // stableExchangeRate = 1e18 (1:1)
        "1000000000", // maxFeeFixed (high for testing)
        "10000", // maxFeeBps = 100%
        "0", // executionFee
      ],
    ]
  );

  const paramsHash = ethersUtils.keccak256(paramsEncoded);

  // Merkle leaf: keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))))
  // This is OpenZeppelin's double-hash standard to prevent leaf/internal-node ambiguity.
  const innerEncoding = ethersUtils.defaultAbiCoder.encode(
    ["address", "bytes32"],
    [spokePoolDepositImplEvm, paramsHash]
  );
  const innerHash = ethersUtils.keccak256(innerEncoding);
  const leaf = ethersUtils.keccak256(innerHash);

  // For a single-leaf tree, the merkle root IS the leaf (proof is empty).
  const merkleRoot = leaf;

  console.log(`\n--- Merkle tree ---`);
  console.log(`  paramsHash:     ${paramsHash}`);
  console.log(`  innerEncoding:  abi.encode(${spokePoolDepositImplEvm}, ${paramsHash})`);
  console.log(`  innerHash:      ${innerHash}`);
  console.log(`  leaf (root):    ${merkleRoot}`);
  console.log(`  proof:          [] (single leaf)`);

  // Salt
  const salt = ethersUtils.id("test-clone-" + Date.now());
  console.log(`  salt:           ${salt}`);

  // --- Predict address ---
  console.log(`\n--- Predicting clone address ---`);
  const predictResult = await tronWeb.transactionBuilder.triggerConstantContract(
    factoryTronHex,
    "predictDepositAddress(address,bytes32,bytes32)",
    {},
    [
      { type: "address", value: counterfactualDepositImplEvm },
      { type: "bytes32", value: merkleRoot },
      { type: "bytes32", value: salt },
    ]
  );

  const predictedEvm = "0x" + predictResult.constant_result[0].slice(24);
  const predictedTronHex = "41" + predictResult.constant_result[0].slice(24);
  const predictedBase58 = tronWeb.address.fromHex(predictedTronHex) as string;
  console.log(`  Predicted: ${predictedBase58} (${predictedEvm})`);

  // --- Deploy clone ---
  console.log(`\n--- Deploying clone ---`);
  const deployTx = await tronWeb.transactionBuilder.triggerSmartContract(
    factoryTronHex,
    "deploy(address,bytes32,bytes32)",
    { feeLimit },
    [
      { type: "address", value: counterfactualDepositImplEvm },
      { type: "bytes32", value: merkleRoot },
      { type: "bytes32", value: salt },
    ]
  );

  if (!deployTx.result?.result) {
    console.log("Error: deploy failed:", JSON.stringify(deployTx, null, 2));
    process.exit(1);
  }

  const signedDeploy = await tronWeb.trx.sign(deployTx.transaction);
  const deployResult = await tronWeb.trx.sendRawTransaction(signedDeploy);
  if (!(deployResult as any).result) {
    console.log("Error: deploy rejected:", JSON.stringify(deployResult, null, 2));
    process.exit(1);
  }

  const deployTxID = (deployResult as any).txid || (deployResult as any).transaction?.txID;
  console.log(`  Deploy tx: ${deployTxID}`);
  const deployInfo = await waitForConfirmation(tronWeb, deployTxID);

  if (deployInfo.receipt?.result !== "SUCCESS") {
    console.log("Error: clone deploy failed:", JSON.stringify(deployInfo, null, 2));
    process.exit(1);
  }

  console.log(`\nClone deployed!`);
  console.log(`  Address:  ${predictedBase58} (${predictedEvm})`);
  console.log(`  TX ID:    ${deployTxID}`);
  console.log(`  Energy:   ${deployInfo.receipt?.energy_usage_total}`);
  console.log(`  Tronscan: ${tronscanBase}/#/transaction/${deployTxID}`);

  console.log(`\n--- Execute script command ---`);
  console.log(
    `yarn tron-execute-clone-deposit ${predictedBase58} ${spokePoolDepositImpl} ${inputTokenAddress} <amount>${chainId !== TRON_MAINNET_CHAIN_ID ? " --testnet" : ""}`
  );
}

async function waitForConfirmation(tronWeb: TronWeb, txID: string): Promise<any> {
  for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    const txInfo = await tronWeb.trx.getTransactionInfo(txID);
    if (txInfo && (txInfo as any).id) return txInfo;
    console.log(`  Waiting... (${i + 1}/${MAX_POLL_ATTEMPTS})`);
  }
  console.log("Error: not confirmed within timeout.");
  process.exit(1);
}

main().catch((err) => {
  console.log("Fatal error:", err.message || err);
  process.exit(1);
});
