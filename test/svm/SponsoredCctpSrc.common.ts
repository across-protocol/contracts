import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { PublicKey } from "@solana/web3.js";
import { ethers } from "ethers";
import { evmAddressToPublicKey } from "../../src/svm/web3-v1";
import { SponsoredCctpSrcPeriphery } from "../../target/types/sponsored_cctp_src_periphery";
import { SponsoredCCTPQuote, SponsoredCCTPQuoteSVM } from "./SponsoredCctpSrc.types";

export const provider = anchor.AnchorProvider.env();
export const program = anchor.workspace.SponsoredCctpSrcPeriphery as Program<SponsoredCctpSrcPeriphery>;
export const connection = provider.connection;
export const owner = provider.wallet.publicKey;
const solanaDomain = 5; // CCTP domain.

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
  sourceDomain = solanaDomain,
  signer = PublicKey.default,
}: { seed?: BN; sourceDomain?: number; signer?: PublicKey } = {}) {
  const seeds = [Buffer.from("state")];
  const [state] = PublicKey.findProgramAddressSync(seeds, program.programId);
  const programData = getProgramData();
  await program.methods
    .initialize({ sourceDomain, signer })
    .accounts({ program: program.programId, programData })
    .rpc();
  return { programData, state, sourceDomain, signer };
}
