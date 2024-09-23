import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { PublicKey, Keypair } from "@solana/web3.js";
import { ethers } from "ethers";
import { ASSOCIATED_TOKEN_PROGRAM_ID, TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
import { SvmSpoke } from "../../target/types/svm_spoke";
import { evmAddressToPublicKey } from "../../src/SvmUtils";
import { assert } from "chai";

const provider = anchor.AnchorProvider.env();
const program = anchor.workspace.SvmSpoke as Program<SvmSpoke>;
const owner = provider.wallet.publicKey;
const chainId = new BN(420);
const remoteDomain = 0;
const crossDomainAdmin = evmAddressToPublicKey(ethers.Wallet.createRandom().address);

const seedBalance = 20000000;
const destinationChainId = new BN(1);
const recipient = Keypair.generate().publicKey;
const exclusiveRelayer = Keypair.generate().publicKey;
const outputToken = new PublicKey("1111111111113EsMD5n1VA94D2fALdb1SAKLam8j"); // TODO: this is lazy. this is cast USDC from Eth mainnet.
const inputAmount = new BN(500000);
const outputAmount = inputAmount;
const quoteTimestamp = new BN(Math.floor(Date.now() / 1000));
const fillDeadline = new BN(Math.floor(Date.now() / 1000) + 600);
const exclusivityDeadline = new BN(Math.floor(Date.now() / 1000) + 300);
const message = Buffer.from("Test message");

const initializeState = async (seed?: BN) => {
  const actualSeed = seed || new BN(Math.floor(Math.random() * 1000000));
  const seeds = [Buffer.from("state"), actualSeed.toArrayLike(Buffer, "le", 8)];
  const [state] = PublicKey.findProgramAddressSync(seeds, program.programId);
  await program.methods
    .initialize(actualSeed, new BN(0), chainId, remoteDomain, crossDomainAdmin, true)
    .accounts({
      state: state as any,
      signer: owner,
      systemProgram: anchor.web3.SystemProgram.programId,
    })
    .rpc();
  return state;
};

const createRoutePda = (originToken: PublicKey, state: PublicKey, routeChainId: BN) => {
  return PublicKey.findProgramAddressSync(
    [Buffer.from("route"), originToken.toBytes(), state.toBytes(), routeChainId.toArrayLike(Buffer, "le", 8)],
    program.programId
  )[0];
};

const getVaultAta = (tokenMint: PublicKey, state: PublicKey) => {
  return getAssociatedTokenAddressSync(tokenMint, state, true, TOKEN_PROGRAM_ID, ASSOCIATED_TOKEN_PROGRAM_ID);
};

async function setCurrentTime(program: Program<SvmSpoke>, state: any, signer: anchor.web3.Keypair, newTime: BN) {
  await program.methods.setCurrentTime(newTime).accounts({ state, signer: signer.publicKey }).signers([signer]).rpc();
}

function assertSE(a: any, b: any, errorMessage: string) {
  assert.strictEqual(a.toString(), b.toString(), errorMessage);
}

export const common = {
  provider,
  connection: provider.connection,
  program,
  owner,
  chainId,
  remoteDomain,
  crossDomainAdmin,
  seedBalance,
  destinationChainId,
  recipient,
  exclusiveRelayer,
  outputToken,
  inputAmount,
  outputAmount,
  quoteTimestamp,
  fillDeadline,
  exclusivityDeadline,
  message,
  initializeState,
  createRoutePda,
  getVaultAta,
  setCurrentTime,
  assert,
  assertSE,
  depositData: {
    depositor: null, // Placeholder, to be assigned in the test file
    recipient,
    inputToken: null, // Placeholder, to be assigned in the test file
    outputToken,
    inputAmount,
    outputAmount,
    destinationChainId,
    exclusiveRelayer,
    quoteTimestamp,
    fillDeadline,
    exclusivityDeadline,
    message,
  },
};
