#!/usr/bin/env ts-node
/**
 * Executes a deposit through a deployed counterfactual clone on Tron.
 *
 * Steps:
 *   1. Transfer tokens to the clone
 *   2. Sign EIP-712 ExecuteDeposit (verifyingContract = clone address)
 *   3. Call clone.execute(implementation, params, submitterData, proof)
 *
 * The route params (destination chain, tokens, recipient, fee settings) are reconstructed
 * identically to test-deploy-clone.ts so the merkle proof validates.
 *
 * Env vars:
 *   MNEMONIC              — BIP-39 mnemonic (derives account 0 private key, also used as signer)
 *   NODE_URL_728126428    — Tron mainnet full node URL
 *   NODE_URL_3448148188   — Tron Nile testnet full node URL
 *   TRON_FEE_LIMIT        — optional, in sun (default: 100000000 = 100 TRX)
 *
 * Options:
 *   --testnet  — use Tron Nile testnet (default: mainnet)
 *
 * Usage:
 *   yarn test-execute-clone-deposit <clone-address> <spokepool-deposit-impl> <input-token> <input-amount> [--testnet]
 *
 * Addresses in Tron Base58Check format (T...). input-amount in token base units.
 */

import "dotenv/config";
import { TronWeb } from "tronweb";
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
  const cloneAddress = args[0];
  const spokePoolDepositImpl = args[1];
  const inputTokenAddress = args[2];
  const inputAmountStr = args[3];

  if (!cloneAddress || !spokePoolDepositImpl || !inputTokenAddress || !inputAmountStr) {
    console.log(
      "Usage: yarn test-execute-clone-deposit <clone-address> <spokepool-deposit-impl> <input-token> <input-amount> [--testnet]"
    );
    process.exit(1);
  }

  validateTronAddresses({
    clone: cloneAddress,
    "spokepool-deposit-impl": spokePoolDepositImpl,
    "input-token": inputTokenAddress,
  });

  const inputAmount = BigInt(inputAmountStr);
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
  const cloneEvmAddress = tronToEvmAddress(cloneAddress);
  const spokePoolDepositImplEvm = tronToEvmAddress(spokePoolDepositImpl);
  const inputTokenEvmAddress = tronToEvmAddress(inputTokenAddress);
  const tronscanBase = TRONSCAN_URLS[chainId] || "https://tronscan.org";

  console.log("=== Execute Clone Deposit ===");
  console.log(`Chain ID:              ${chainId}`);
  console.log(`Clone:                 ${cloneAddress} (${cloneEvmAddress})`);
  console.log(`SpokePoolDeposit impl: ${spokePoolDepositImpl} (${spokePoolDepositImplEvm})`);
  console.log(`Input token:           ${inputTokenAddress} (${inputTokenEvmAddress})`);
  console.log(`Input amount:          ${inputAmount.toString()}`);
  console.log(`Signer:                ${signerEvmAddress}`);

  // --- Step 1: Sign EIP-712 ---
  // verifyingContract = clone address (delegatecall preserves address(this))
  console.log("\n--- Step 1: Signing EIP-712 ExecuteDeposit ---");

  const now = Math.floor(Date.now() / 1000);
  const quoteTimestamp = now;
  const fillDeadline = now + 21600;
  const signatureDeadline = now + 3600;
  const exclusivityDeadline = 0;
  const outputAmount = (inputAmount * 99n) / 100n;
  const executionFee = 0n;
  const exclusiveRelayer = "0x" + "00".repeat(32);

  const domain = {
    name: "CounterfactualDepositSpokePool",
    version: "v1.0.0",
    chainId: parseInt(chainId),
    verifyingContract: cloneEvmAddress,
  };

  const types = {
    ExecuteDeposit: [
      { name: "inputAmount", type: "uint256" },
      { name: "outputAmount", type: "uint256" },
      { name: "exclusiveRelayer", type: "bytes32" },
      { name: "exclusivityDeadline", type: "uint32" },
      { name: "quoteTimestamp", type: "uint32" },
      { name: "fillDeadline", type: "uint32" },
      { name: "signatureDeadline", type: "uint32" },
    ],
  };

  const eip712Message = {
    inputAmount: inputAmount.toString(),
    outputAmount: outputAmount.toString(),
    exclusiveRelayer,
    exclusivityDeadline,
    quoteTimestamp,
    fillDeadline,
    signatureDeadline,
  };

  const signature = await wallet.signTypedData(domain, types, eip712Message);
  console.log(`  Signature: ${signature}`);

  // --- Step 2: Call execute on clone ---
  console.log("\n--- Step 2: Calling clone.execute() ---");

  // Reconstruct the same params encoding used by test-deploy-clone.ts.
  // These must match exactly so keccak256(params) produces the same leaf.
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
        "1000000000000000000", // stableExchangeRate = 1e18
        "1000000000", // maxFeeFixed (must match deploy script)
        "10000", // maxFeeBps = 100%
        executionFee.toString(),
      ],
    ]
  );

  const submitterDataEncoded = tronWeb.utils.abi.encodeParams(
    ["(uint256,uint256,bytes32,uint32,address,uint32,uint32,uint32,bytes)"],
    [
      [
        inputAmount.toString(),
        outputAmount.toString(),
        exclusiveRelayer,
        exclusivityDeadline,
        signerEvmAddress,
        quoteTimestamp,
        fillDeadline,
        signatureDeadline,
        signature,
      ],
    ]
  );

  // Single-leaf merkle tree: proof is empty.
  const merkleProof: string[] = [];

  // Clone's execute: execute(address implementation, bytes params, bytes submitterData, bytes32[] proof)
  const cloneExecuteAbi = [
    {
      type: "function",
      name: "execute",
      inputs: [
        { name: "implementation", type: "address" },
        { name: "params", type: "bytes" },
        { name: "submitterData", type: "bytes" },
        { name: "proof", type: "bytes32[]" },
      ],
      outputs: [],
      stateMutability: "payable",
    },
  ];

  const cloneContract = tronWeb.contract(cloneExecuteAbi, cloneAddress);
  const executeTxID: string = await cloneContract.methods
    .execute(spokePoolDepositImplEvm, paramsEncoded, submitterDataEncoded, merkleProof)
    .send({ feeLimit });

  console.log(`  Execute tx: ${executeTxID}`);
  const txInfo = await waitForConfirmation(tronWeb, executeTxID);

  if (txInfo.receipt?.result !== "SUCCESS") {
    console.log("Error: execute failed:", JSON.stringify(txInfo, null, 2));
    process.exit(1);
  }

  console.log(`\nDeposit executed!`);
  console.log(`  Clone:    ${cloneAddress}`);
  console.log(`  TX ID:    ${executeTxID}`);
  console.log(`  Tronscan: ${tronscanBase}/#/transaction/${executeTxID}`);
  console.log(`  Energy:   ${txInfo.receipt?.energy_usage_total || "unknown"}`);
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
