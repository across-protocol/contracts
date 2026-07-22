/**
 * Script: Verify the 2026-07 Solana Residual Recovery Leaf
 *
 * Recomputes the relayer refund root and pool rebalance root for the recovery leaf in
 * `leaf.json` using this repo's own hashing code, and re-derives the recoverable amount from
 * live chain state: SpokePool vault balance minus the sum of outstanding ClaimAccount
 * liabilities minus any USDC already queued to the hub pool (pending TransferLiability).
 * Also requires deposits and fills to still be paused — the derivation is only sound while
 * no user flow can move the vault. Fails (exit 1) on any mismatch. See README.md in this
 * directory.
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
import { relayerRefundHashFn, SOLANA_SPOKE_STATE_SEED } from "../../../../src/svm/web3-v1";
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

  // 3. Live state guards. The derivation is only sound while deposits and fills are paused (no
  //    user flow can move the vault), and any USDC already queued to the hub pool by a prior
  //    return (pending TransferLiability) still sits in the vault but is already spoken for.
  const connection = new Connection(process.env.SOLANA_RPC_URL ?? "https://api.mainnet-beta.solana.com");
  const [statePda] = PublicKey.findProgramAddressSync(
    [Buffer.from("state"), SOLANA_SPOKE_STATE_SEED.toArrayLike(Buffer, "le", 8)],
    SVM_SPOKE_PROGRAM
  );
  const stateInfo = await connection.getAccountInfo(statePda, "finalized");
  if (stateInfo === null) throw new Error(`State account ${statePda.toString()} not found`);
  // State layout: 8-byte discriminator, then paused_deposits: bool, paused_fills: bool.
  const pausedDeposits = stateInfo.data[8] === 1;
  const pausedFills = stateInfo.data[9] === 1;

  const [transferLiabilityPda] = PublicKey.findProgramAddressSync(
    [Buffer.from("transfer_liability"), new PublicKey(expected.leaf.mintPublicKey).toBuffer()],
    SVM_SPOKE_PROGRAM
  );
  const liabilityInfo = await connection.getAccountInfo(transferLiabilityPda, "finalized");
  // TransferLiability layout: 8-byte discriminator, then pending_to_hub_pool: u64.
  const pendingToHubPool = liabilityInfo === null ? BigInt(0) : liabilityInfo.data.readBigUInt64LE(8);

  // 4. Live state: vault balance net of ClaimAccount liabilities and queued hub-pool liability.
  const vaultBalance = BigInt((await connection.getTokenAccountBalance(VAULT, "finalized")).value.amount);
  const claimAccounts = await connection.getProgramAccounts(SVM_SPOKE_PROGRAM, {
    filters: [{ dataSize: 48 }, { memcmp: { offset: 0, bytes: utils.bytes.bs58.encode(CLAIM_ACCOUNT_DISCRIMINATOR) } }],
  });
  const claimTotal = claimAccounts.reduce((sum, { account }) => sum + account.data.readBigUInt64LE(8), BigInt(0));
  const recoverable = vaultBalance - claimTotal - pendingToHubPool;

  const rootsMatch =
    relayerRefundRoot === expected.relayerRefundRoot && poolRebalanceRoot === expected.poolRebalanceRoot;
  const amountMatches = recoverable === BigInt(expected.leaf.amountToReturn);
  const pausesActive = pausedDeposits && pausedFills;

  console.table([
    { Check: "relayerRefundRoot (recomputed)", Value: relayerRefundRoot },
    { Check: "relayerRefundRoot (expected)", Value: expected.relayerRefundRoot },
    { Check: "poolRebalanceRoot (recomputed)", Value: poolRebalanceRoot },
    { Check: "poolRebalanceRoot (expected)", Value: expected.poolRebalanceRoot },
    { Check: "deposits paused (live)", Value: pausedDeposits },
    { Check: "fills paused (live)", Value: pausedFills },
    { Check: "vault balance (live)", Value: vaultBalance.toString() },
    { Check: `claim accounts total (live, ${claimAccounts.length} accounts)`, Value: claimTotal.toString() },
    { Check: "pending transfer liability (live)", Value: pendingToHubPool.toString() },
    { Check: "recoverable = vault - claims - pending liability", Value: recoverable.toString() },
    { Check: "leaf amountToReturn", Value: expected.leaf.amountToReturn },
    { Check: "roots match", Value: rootsMatch },
    { Check: "amount matches live state", Value: amountMatches },
  ]);

  if (!pausesActive) {
    console.error("❌ Deposits and/or fills are unpaused. The vault is no longer frozen, so the residual");
    console.error("   derivation is stale. Re-pause (or re-derive the amount) before proposing this leaf.");
    process.exit(1);
  }
  if (!rootsMatch || !amountMatches) {
    console.error("❌ Verification failed. Do not propose this leaf without re-deriving the amount.");
    process.exit(1);
  }
  console.log("✅ Pauses active; leaf, roots, and live recoverable amount all verified.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
