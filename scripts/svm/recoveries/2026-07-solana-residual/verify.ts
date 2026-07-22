/**
 * Script: Verify the 2026-07 Solana Residual Recovery Leaf
 *
 * Recomputes the relayer refund root and pool rebalance root for the recovery leaf in
 * `leaf.json` using this repo's own hashing code, and re-derives the recoverable amount from
 * live chain state: SpokePool vault balance minus the sum of outstanding ClaimAccount
 * liabilities. Fails (exit 1) on any mismatch. See README.md in this directory.
 *
 * Optional Environment Variables:
 * - SOLANA_RPC_URL: Solana mainnet RPC (defaults to the public endpoint).
 *
 * Example Usage:
 * anchor run verifySolanaResidualRecovery
 */

import { BN, utils } from "@coral-xyz/anchor";
import { Connection, PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { readFileSync } from "fs";
import * as path from "path";
import { relayerRefundHashFn } from "../../../../src/svm/web3-v1";
import { RelayerRefundLeafSolana, RelayerRefundLeafType } from "../../../../src/types/svm";
import { MerkleTree } from "../../../../utils/MerkleTree";

const SVM_SPOKE_PROGRAM = new PublicKey("DLv3NggMiSaef97YCkew5xKUHDh13tVGZ7tydt3ZeAru");
const VAULT = new PublicKey("HYhZwefNFmEm9sXYKkNM4QPMgGQnS9VjC6kgxwrGk3Ru");
// Anchor account discriminator: sha256("account:ClaimAccount")[0..8].
const CLAIM_ACCOUNT_DISCRIMINATOR = Buffer.from([113, 109, 47, 96, 242, 219, 61, 165]);

async function main(): Promise<void> {
  const expected = JSON.parse(readFileSync(path.join(__dirname, "leaf.json"), "utf8"));

  // 1. Recompute the relayer refund root from the leaf definition (single leaf tree).
  const leaf: RelayerRefundLeafSolana = {
    isSolana: true,
    leafId: new BN(expected.leaf.leafId),
    chainId: new BN(expected.leaf.chainId),
    amountToReturn: new BN(expected.leaf.amountToReturn),
    mintPublicKey: new PublicKey(expected.leaf.mintPublicKey),
    refundAddresses: [],
    refundAmounts: [],
  };
  const relayerRefundRoot = new MerkleTree<RelayerRefundLeafType>([leaf], relayerRefundHashFn).getHexRoot();

  // 2. Recompute the (empty) pool rebalance root, mirroring constructEmptyPoolRebalanceTree.
  const rebalanceParamType =
    "tuple( uint256 chainId, uint256[] bundleLpFees, int256[] netSendAmounts, int256[] runningBalances, uint256 groupIndex, uint8 leafId, address[] l1Tokens )";
  const poolRebalanceRoot = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      [rebalanceParamType],
      [
        {
          chainId: expected.leaf.chainId,
          bundleLpFees: [],
          netSendAmounts: [],
          runningBalances: [],
          groupIndex: 0,
          leafId: 0,
          l1Tokens: [],
        },
      ]
    )
  );

  // 3. Live state: vault balance and outstanding ClaimAccount liabilities.
  const connection = new Connection(process.env.SOLANA_RPC_URL ?? "https://api.mainnet-beta.solana.com");
  const vaultBalance = BigInt((await connection.getTokenAccountBalance(VAULT, "finalized")).value.amount);
  const claimAccounts = await connection.getProgramAccounts(SVM_SPOKE_PROGRAM, {
    filters: [
      { dataSize: 48 },
      { memcmp: { offset: 0, bytes: utils.bytes.bs58.encode(CLAIM_ACCOUNT_DISCRIMINATOR) } },
    ],
  });
  const claimTotal = claimAccounts.reduce((sum, { account }) => sum + account.data.readBigUInt64LE(8), BigInt(0));
  const recoverable = vaultBalance - claimTotal;

  const rootsMatch =
    relayerRefundRoot === expected.relayerRefundRoot && poolRebalanceRoot === expected.poolRebalanceRoot;
  const amountMatches = recoverable === BigInt(expected.leaf.amountToReturn);

  console.table([
    { Check: "relayerRefundRoot (recomputed)", Value: relayerRefundRoot },
    { Check: "relayerRefundRoot (expected)", Value: expected.relayerRefundRoot },
    { Check: "poolRebalanceRoot (recomputed)", Value: poolRebalanceRoot },
    { Check: "poolRebalanceRoot (expected)", Value: expected.poolRebalanceRoot },
    { Check: "vault balance (live)", Value: vaultBalance.toString() },
    { Check: `claim accounts total (live, ${claimAccounts.length} accounts)`, Value: claimTotal.toString() },
    { Check: "recoverable = vault - claims", Value: recoverable.toString() },
    { Check: "leaf amountToReturn", Value: expected.leaf.amountToReturn },
    { Check: "roots match", Value: rootsMatch },
    { Check: "amount matches live state", Value: amountMatches },
  ]);

  if (!rootsMatch || !amountMatches) {
    console.error("❌ Verification failed. Do not propose this leaf without re-deriving the amount.");
    process.exit(1);
  }
  console.log("✅ Leaf, roots, and live recoverable amount all verified.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
