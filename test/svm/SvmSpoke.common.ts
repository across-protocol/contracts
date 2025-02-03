import * as anchor from "@coral-xyz/anchor";
import { BN, Program } from "@coral-xyz/anchor";
import { ASSOCIATED_TOKEN_PROGRAM_ID, getAssociatedTokenAddressSync } from "@solana/spl-token";
import { Keypair, PublicKey } from "@solana/web3.js";
import { assert } from "chai";
import { randomBytes } from "crypto";
import { ethers } from "ethers";
import { evmAddressToPublicKey } from "../../src/svm/web3-v1";
import { DepositData } from "../../src/types/svm";
import { SvmSpoke } from "../../target/types/svm_spoke";

const provider = anchor.AnchorProvider.env();
const program = anchor.workspace.SvmSpoke as Program<SvmSpoke>;
const owner = provider.wallet.publicKey;
const chainId = new BN(420);
const remoteDomain = new BN(0); // Ethereum
const localDomain = 5; // Solana
const crossDomainAdmin = evmAddressToPublicKey(ethers.Wallet.createRandom().address);

const seedBalance = 20000000;
const destinationChainId = new BN(1);
const recipient = Keypair.generate().publicKey;
const exclusiveRelayer = Keypair.generate().publicKey;
const outputToken = new PublicKey("1111111111113EsMD5n1VA94D2fALdb1SAKLam8j"); // TODO: this is lazy. this is cast USDC from Eth mainnet.
const inputAmount = new BN(500000);
const outputAmount = inputAmount;
const quoteTimestamp = new BN(Math.floor(Date.now() / 1000) - 60); // 60 seconds ago.
const fillDeadline = new BN(Math.floor(Date.now() / 1000) + 600); // 600 seconds from now.
const exclusivityParameter = new BN(0); // 0 means no exclusivity and disables this. Set to special values in tests.
const message = Buffer.from("Test message");
const depositQuoteTimeBuffer = new BN(3600); // 1 hour.
const fillDeadlineBuffer = new BN(3600 * 4); // 4 hours.

const initializeState = async (
  seed?: BN,
  initialState?: {
    initialNumberOfDeposits: BN;
    chainId: BN;
    remoteDomain: BN;
    crossDomainAdmin: PublicKey;
    depositQuoteTimeBuffer: BN;
    fillDeadlineBuffer: BN;
  }
) => {
  const actualSeed = seed || new BN(randomBytes(8).toString("hex"), 16); // Generate a random u64
  const seeds = [Buffer.from("state"), actualSeed.toArrayLike(Buffer, "le", 8)];
  const [state] = PublicKey.findProgramAddressSync(seeds, program.programId);
  if (!initialState) {
    initialState = {
      initialNumberOfDeposits: new BN(0),
      chainId,
      remoteDomain,
      crossDomainAdmin,
      depositQuoteTimeBuffer,
      fillDeadlineBuffer,
    };
  }
  const initializeAccounts = { state: state as any, signer: owner, systemProgram: anchor.web3.SystemProgram.programId };
  await program.methods
    .initialize(
      actualSeed,
      initialState.initialNumberOfDeposits.toNumber(),
      initialState.chainId,
      initialState.remoteDomain.toNumber(),
      initialState.crossDomainAdmin,
      initialState.depositQuoteTimeBuffer.toNumber(),
      initialState.fillDeadlineBuffer.toNumber()
    )
    .accounts(initializeAccounts)
    .rpc();
  return { state, seed: actualSeed };
};

const createRoutePda = (originToken: PublicKey, seed: BN, routeChainId: BN) => {
  return PublicKey.findProgramAddressSync(
    [
      Buffer.from("route"),
      originToken.toBytes(),
      seed.toArrayLike(Buffer, "le", 8),
      routeChainId.toArrayLike(Buffer, "le", 8),
    ],
    program.programId
  )[0];
};

const getVaultAta = async (tokenMint: PublicKey, state: PublicKey) => {
  const tokenMintAccount = await provider.connection.getAccountInfo(tokenMint);
  if (tokenMintAccount === null) throw new Error("Token Mint account not found");
  return getAssociatedTokenAddressSync(tokenMint, state, true, tokenMintAccount.owner, ASSOCIATED_TOKEN_PROGRAM_ID);
};

async function setCurrentTime(program: Program<SvmSpoke>, state: any, signer: anchor.web3.Keypair, newTime: BN) {
  let setCurrentTimeAccounts = { state, signer: signer.publicKey };
  await program.methods.setCurrentTime(newTime.toNumber()).accounts(setCurrentTimeAccounts).signers([signer]).rpc();
}

async function getCurrentTime(program: Program<SvmSpoke>, state: any) {
  return (await program.account.state.fetch(state)).currentTime;
}

function assertSE(a: any, b: any, errorMessage: string) {
  if (a === undefined || b === undefined) {
    throw new Error("Undefined value " + errorMessage);
  } else {
    assert.strictEqual(a.toString(), b.toString(), errorMessage);
  }
}

export const common = {
  provider,
  connection: provider.connection,
  program,
  owner,
  chainId,
  remoteDomain,
  localDomain,
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
  exclusivityParameter,
  message,
  depositQuoteTimeBuffer,
  fillDeadlineBuffer,
  initializeState,
  createRoutePda,
  getVaultAta,
  setCurrentTime,
  getCurrentTime,
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
    exclusivityParameter,
    message,
  } as DepositData,
};
