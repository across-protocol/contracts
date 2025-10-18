import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { randomBytes } from "crypto";
import { ethers } from "ethers";
import { evmAddressToPublicKey } from "../../src/svm/web3-v1";
import { SponsoredCctpSrcPeriphery } from "../../target/types/sponsored_cctp_src_periphery";

export const provider = anchor.AnchorProvider.env();
export const program = anchor.workspace.SponsoredCctpSrcPeriphery as Program<SponsoredCctpSrcPeriphery>;
export const owner = provider.wallet.publicKey;
const solanaDomain = 5; // CCTP domain.

const randomSeed = new BN(randomBytes(8).toString("hex"), 16); // Default to random u64 seed.

export function createQuoteSigner(): { quoteSigner: ethers.Wallet; quoteSignerPubkey: PublicKey } {
  const quoteSigner = ethers.Wallet.createRandom();
  const quoteSignerPubkey = evmAddressToPublicKey(quoteSigner.address);
  return { quoteSigner, quoteSignerPubkey };
}

export function getProgramData(): PublicKey {
  const [programData] = PublicKey.findProgramAddressSync(
    [program.programId.toBuffer()],
    new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111")
  );
  return programData;
}

export async function initializeState({
  seed = randomSeed,
  localDomain = solanaDomain,
  quoteSigner = PublicKey.default,
}: { seed?: BN; localDomain?: number; quoteSigner?: PublicKey } = {}) {
  const seeds = [Buffer.from("state"), seed.toArrayLike(Buffer, "le", 8)];
  const [state] = PublicKey.findProgramAddressSync(seeds, program.programId);
  const programData = getProgramData();
  await program.methods
    .initialize({ seed, localDomain, quoteSigner })
    .accounts({ program: program.programId, programData })
    .rpc();
  return { programData, state, seed, localDomain, quoteSigner };
}
