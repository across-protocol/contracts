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
const quoteTimestamp = new BN(Math.floor(Date.now() / 1000) - 50); // 10 seconds ago.
const fillDeadline = new BN(Math.floor(Date.now() / 1000) + 600); // 600 seconds from now.
const exclusivityPeriod = new BN(300); // 300 seconds.
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
  const actualSeed = seed || new BN(Math.floor(Math.random() * 1000000));
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
  let setCurrentTimeAccounts = { state, signer: signer.publicKey };
  await program.methods.setCurrentTime(newTime.toNumber()).accounts(setCurrentTimeAccounts).signers([signer]).rpc();
}

async function getCurrentTime(program: Program<SvmSpoke>, state: any) {
  return (await program.account.state.fetch(state)).currentTime;
}

function assertSE(a: any, b: any, errorMessage: string) {
  if (a === undefined || b === undefined) {
    assert.strictEqual(a, b, errorMessage);
  } else {
    assert.strictEqual(a.toString(), b.toString(), errorMessage);
  }
}

interface DepositData {
  depositor: PublicKey | null; // Adjust type as necessary
  recipient: PublicKey;
  inputToken: PublicKey | null; // Adjust type as necessary
  outputToken: PublicKey;
  inputAmount: BN;
  outputAmount: BN;
  destinationChainId: BN;
  exclusiveRelayer: PublicKey;
  quoteTimestamp: BN;
  fillDeadline: BN;
  exclusivityPeriod: BN;
  message: Buffer;
}

export type DepositDataValues = [
  PublicKey,
  PublicKey,
  PublicKey,
  PublicKey,
  BN,
  BN,
  BN,
  PublicKey,
  number,
  number,
  number,
  Buffer
];

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
  exclusivityPeriod,
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
    exclusivityPeriod,
    message,
  } as DepositData,
};
