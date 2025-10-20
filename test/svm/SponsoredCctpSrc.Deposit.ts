import * as anchor from "@coral-xyz/anchor";
import { BN, Program, workspace } from "@coral-xyz/anchor";
import { createMint, getOrCreateAssociatedTokenAccount, mintTo, TOKEN_PROGRAM_ID, getAccount } from "@solana/spl-token";
import {
  AddressLookupTableAccount,
  AddressLookupTableProgram,
  Keypair,
  PublicKey,
  sendAndConfirmTransaction,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import { assert } from "chai";
import * as crypto from "crypto";
import { ethers } from "ethers";
import { TokenMessengerMinterV2 } from "../../target/types/token_messenger_minter_v2";
import { MessageTransmitterV2 } from "../../src/svm/assets/message_transmitter_v2";
import { program, provider, initializeState, owner, createQuoteSigner } from "./SponsoredCctpSrc.common";
import { SponsoredCCTPQuote } from "./SponsoredCctpSrc.types";
import {
  findProgramAddress,
  sendTransactionWithExistingLookupTable,
  readEventsUntilFound,
  decodeMessageSentDataV2,
} from "../../src/svm/web3-v1";

describe("sponsored_cctp_src_periphery.deposit", () => {
  anchor.setProvider(provider);

  const tokenMessengerMinterV2Program = workspace.TokenMessengerMinterV2 as Program<TokenMessengerMinterV2>;
  const messageTransmitterV2Program = workspace.MessageTransmitterV2 as Program<MessageTransmitterV2>;

  const { payer } = anchor.AnchorProvider.env().wallet as anchor.Wallet;

  const depositor = Keypair.generate();
  const { quoteSigner, quoteSignerPubkey } = createQuoteSigner();

  const tokenDecimals = 6;
  const seedBalance = BigInt(ethers.utils.parseUnits("1000000", tokenDecimals).toString());
  const burnAmount = ethers.utils.parseUnits("1000", 6);
  const remoteDomain = new BN(0); // Ethereum
  const mintRecipient = ethers.utils.arrayify(ethers.utils.id("mintRecipient"));
  const destinationCaller = ethers.utils.arrayify(ethers.utils.id("destinationCaller"));
  const finalRecipient = ethers.utils.arrayify(ethers.utils.id("finalRecipient"));
  const finalToken = ethers.utils.arrayify(ethers.utils.id("finalToken"));
  const maxFee = 100;
  const minFinalityThreshold = 5;
  const maxBpsToSponsor = 500;

  let sourceDomain: number;
  let messageSentEventData: Keypair;
  let lookupTableAccount: AddressLookupTableAccount;
  let state: PublicKey,
    tokenProgram: PublicKey,
    burnToken: PublicKey,
    depositorTokenAccount: PublicKey,
    denylistAccount: PublicKey,
    tokenMessengerMinterSenderAuthority: PublicKey,
    messageTransmitter: PublicKey,
    tokenMessenger: PublicKey,
    remoteTokenMessenger: PublicKey,
    tokenMinter: PublicKey,
    localToken: PublicKey,
    cctpEventAuthority: PublicKey,
    rentFund: PublicKey;

  const getDenyList = (user: PublicKey): PublicKey => {
    const [denyList] = PublicKey.findProgramAddressSync(
      [Buffer.from("denylist_account"), user.toBuffer()],
      tokenMessengerMinterV2Program.programId
    );
    return denyList;
  };

  const signSponsoredCCTPQuote = async (
    signer: ethers.Wallet,
    quoteData: SponsoredCCTPQuote
  ): Promise<{ quote: number[]; signature: number[] }> => {
    const encodedHexString = ethers.utils.defaultAbiCoder.encode(
      [
        "uint32",
        "uint32",
        "bytes32",
        "uint256",
        "bytes32",
        "bytes32",
        "uint256",
        "uint32",
        "bytes32",
        "uint256",
        "uint256",
        "bytes32",
        "bytes32",
      ],
      [
        quoteData.sourceDomain,
        quoteData.destinationDomain,
        quoteData.mintRecipient,
        quoteData.amount,
        quoteData.burnToken,
        quoteData.destinationCaller,
        quoteData.maxFee,
        quoteData.minFinalityThreshold,
        quoteData.nonce,
        quoteData.deadline,
        quoteData.maxBpsToSponsor,
        quoteData.finalRecipient,
        quoteData.finalToken,
      ]
    );
    const encodedQuote = Array.from(Buffer.from(ethers.utils.arrayify(encodedHexString)));

    const digest = ethers.utils.keccak256(encodedHexString);

    // Create simple ECDSA signature over the ABI encoded quote data hash.
    const signatureHexString = ethers.utils.joinSignature(signer._signingKey().signDigest(digest));
    const signature = Array.from(Buffer.from(ethers.utils.arrayify(signatureHexString)));

    return { quote: encodedQuote, signature };
  };

  const getHookDataFromQuote = (quoteData: SponsoredCCTPQuote): Buffer => {
    const encodedHexString = ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "uint256", "uint256", "bytes32", "bytes32"],
      [quoteData.nonce, quoteData.deadline, quoteData.maxBpsToSponsor, quoteData.finalRecipient, quoteData.finalToken]
    );

    return Buffer.from(ethers.utils.arrayify(encodedHexString));
  };

  const setupBurnToken = async () => {
    burnToken = await createMint(
      provider.connection,
      payer,
      owner,
      owner,
      tokenDecimals,
      undefined,
      undefined,
      tokenProgram
    );

    depositorTokenAccount = (
      await getOrCreateAssociatedTokenAccount(
        provider.connection,
        payer,
        burnToken,
        depositor.publicKey,
        undefined,
        undefined,
        undefined,
        tokenProgram
      )
    ).address;
    await mintTo(
      provider.connection,
      payer,
      burnToken,
      depositorTokenAccount,
      owner,
      seedBalance,
      undefined,
      undefined,
      tokenProgram
    );

    // Add local CCTP token (test wallet is overridden as token controller in Anchor.toml).
    [localToken] = PublicKey.findProgramAddressSync(
      [Buffer.from("local_token"), burnToken.toBuffer()],
      tokenMessengerMinterV2Program.programId
    );
    const [custodyTokenAccount] = PublicKey.findProgramAddressSync(
      [Buffer.from("custody"), burnToken.toBuffer()],
      tokenMessengerMinterV2Program.programId
    );
    const addLocalTokenAccounts = {
      tokenController: owner,
      tokenMinter,
      localToken,
      custodyTokenAccount,
      localTokenMint: burnToken,
      tokenProgram: TOKEN_PROGRAM_ID,
      systemProgram: SystemProgram.programId,
      program: tokenMessengerMinterV2Program.programId,
      eventAuthority: cctpEventAuthority,
    };
    await tokenMessengerMinterV2Program.methods.addLocalToken({}).accounts(addLocalTokenAccounts).rpc();

    // Set max burn amount per CCTP message for local token to total mint amount.
    const setMaxBurnAmountPerMessageAccounts = {
      tokenMinter,
      localToken,
      program: tokenMessengerMinterV2Program.programId,
      eventAuthority: cctpEventAuthority,
    };
    await tokenMessengerMinterV2Program.methods
      .setMaxBurnAmountPerMessage({ burnLimitPerMessage: new BN(seedBalance.toString()) })
      .accounts(setMaxBurnAmountPerMessageAccounts)
      .rpc();
  };

  const setupCctpAccounts = () => {
    denylistAccount = getDenyList(depositor.publicKey);
    tokenMessengerMinterSenderAuthority = findProgramAddress(
      "sender_authority",
      tokenMessengerMinterV2Program.programId
    ).publicKey;
    messageTransmitter = findProgramAddress("message_transmitter", messageTransmitterV2Program.programId).publicKey;
    tokenMessenger = findProgramAddress("token_messenger", tokenMessengerMinterV2Program.programId).publicKey;
    remoteTokenMessenger = findProgramAddress("remote_token_messenger", tokenMessengerMinterV2Program.programId, [
      remoteDomain.toString(),
    ]).publicKey;
    tokenMinter = findProgramAddress("token_minter", tokenMessengerMinterV2Program.programId).publicKey;
    cctpEventAuthority = findProgramAddress("__event_authority", tokenMessengerMinterV2Program.programId).publicKey;
  };

  const setupLookupTable = async () => {
    // These accounts should be the same for all deposits that have the same burnToken.
    const eventAuthority = findProgramAddress("__event_authority", program.programId).publicKey;
    const lookupAddresses = [
      state,
      burnToken,
      tokenMessengerMinterSenderAuthority,
      messageTransmitter,
      tokenMessenger,
      tokenMinter,
      localToken,
      cctpEventAuthority,
      messageTransmitterV2Program.programId,
      tokenMessengerMinterV2Program.programId,
      tokenProgram,
      SystemProgram.programId,
      eventAuthority,
      rentFund,
    ];

    // Create instructions for creating and extending the ALT.
    const [lookupTableInstruction, lookupTableAddress] = await AddressLookupTableProgram.createLookupTable({
      authority: owner,
      payer: owner,
      recentSlot: await provider.connection.getSlot(),
    });

    // Submit the ALT creation transaction
    await sendAndConfirmTransaction(provider.connection, new Transaction().add(lookupTableInstruction), [payer], {
      commitment: "confirmed",
      skipPreflight: true,
    });

    // Extend the ALT with all accounts.
    const extendInstruction = AddressLookupTableProgram.extendLookupTable({
      lookupTable: lookupTableAddress,
      authority: owner,
      payer: owner,
      addresses: lookupAddresses,
    });

    await sendAndConfirmTransaction(provider.connection, new Transaction().add(extendInstruction), [payer], {
      commitment: "confirmed",
      skipPreflight: true,
    });

    // Wait for slot to advance. ALTs only active after slot advance.
    const initialSlot = await provider.connection.getSlot();
    while ((await provider.connection.getSlot()) === initialSlot) {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }

    // Fetch the AddressLookupTableAccount.
    const fetchedLookupTableAccount = (await provider.connection.getAddressLookupTable(lookupTableAddress)).value;
    if (fetchedLookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");
    lookupTableAccount = fetchedLookupTableAccount;
  };

  const setupRentFund = async () => {
    rentFund = findProgramAddress("rent_fund", program.programId).publicKey;
    await provider.connection.requestAirdrop(rentFund, 1_000_000_000); // 1 SOL
  };

  const getUsedNonce = (nonce: Buffer): PublicKey => {
    const [usedNonce] = PublicKey.findProgramAddressSync([Buffer.from("used_nonce"), nonce], program.programId);
    return usedNonce;
  };

  before(async () => {
    await provider.connection.requestAirdrop(depositor.publicKey, 10_000_000_000); // 10 SOL

    setupCctpAccounts();

    await setupRentFund();
  });

  beforeEach(async () => {
    ({ state, sourceDomain } = await initializeState({ signer: quoteSignerPubkey }));

    tokenProgram = TOKEN_PROGRAM_ID; // Some tests might override this.
    await setupBurnToken();
    await setupLookupTable();

    messageSentEventData = Keypair.generate();
  });

  it("Sponsored CCTP deposit", async () => {
    const nonce = crypto.randomBytes(32);
    const usedNonce = getUsedNonce(nonce);
    const deadline = ethers.BigNumber.from(Math.floor(Date.now() / 1000) + 3600);

    const quoteData: SponsoredCCTPQuote = {
      sourceDomain,
      destinationDomain: remoteDomain.toNumber(),
      mintRecipient: ethers.utils.hexlify(mintRecipient),
      amount: burnAmount,
      burnToken: ethers.utils.hexlify(burnToken.toBuffer()),
      destinationCaller: ethers.utils.hexlify(destinationCaller),
      maxFee,
      minFinalityThreshold,
      nonce: ethers.utils.hexlify(nonce),
      deadline,
      maxBpsToSponsor,
      finalRecipient: ethers.utils.hexlify(finalRecipient),
      finalToken: ethers.utils.hexlify(finalToken),
    };
    const { quote, signature } = await signSponsoredCCTPQuote(quoteSigner, quoteData);

    const depositAccounts = {
      signer: depositor.publicKey,
      payer: depositor.publicKey,
      state,
      rentFund,
      usedNonce,
      depositorTokenAccount,
      burnToken,
      denylistAccount,
      tokenMessengerMinterSenderAuthority,
      messageTransmitter,
      tokenMessenger,
      remoteTokenMessenger,
      tokenMinter,
      localToken,
      cctpEventAuthority,
      tokenProgram,
      messageSentEventData: messageSentEventData.publicKey,
      program: program.programId,
    };
    const depositIx = await program.methods
      .depositForBurn({ quote, signature })
      .accounts(depositAccounts)
      .instruction();
    const txSignature = await sendTransactionWithExistingLookupTable(
      provider.connection,
      [depositIx],
      lookupTableAccount,
      depositor,
      [messageSentEventData]
    );

    const depositorTokenAmount = (await getAccount(provider.connection, depositorTokenAccount)).amount;
    const expectedDepositorTokenAmount = seedBalance - BigInt(burnAmount.toString());
    assert.strictEqual(
      depositorTokenAmount.toString(),
      expectedDepositorTokenAmount.toString(),
      "Depositor token amount mismatch"
    );

    const events = await readEventsUntilFound(provider.connection, txSignature, [program]);

    const depositEvent = events.find((event) => event.name === "sponsoredDepositForBurn")?.data;
    assert.isNotNull(depositEvent, "SponsoredDepositForBurn event should be emitted");
    assert.isTrue(depositEvent.quoteNonce.equals(nonce), "Invalid quoteNonce");
    assert.strictEqual(depositEvent.originSender.toString(), depositor.publicKey.toString(), "Invalid originSender");
    assert.strictEqual(
      depositEvent.finalRecipient.toString(),
      new PublicKey(finalRecipient).toString(),
      "Invalid finalRecipient"
    );
    assert.strictEqual(depositEvent.quoteDeadline.toString(), deadline.toString(), "Invalid quoteDeadline");
    assert.strictEqual(depositEvent.maxBpsToSponsor.toString(), maxBpsToSponsor.toString(), "Invalid maxBpsToSponsor");
    assert.strictEqual(depositEvent.finalToken.toString(), new PublicKey(finalToken).toString(), "Invalid finalToken");
    assert.strictEqual(depositEvent.finalToken.toString(), new PublicKey(finalToken).toString(), "Invalid finalToken");
    assert.isTrue(depositEvent.signature.equals(Buffer.from(signature)), "Invalid signature");

    const createdEventAccountEvent = events.find((event) => event.name === "createdEventAccount")?.data;
    assert.strictEqual(
      createdEventAccountEvent.messageSentEventData.toString(),
      messageSentEventData.publicKey.toString(),
      "Invalid messageSentEventData"
    );

    const message = decodeMessageSentDataV2(
      (await messageTransmitterV2Program.account.messageSent.fetch(messageSentEventData.publicKey)).message
    );
    assert.strictEqual(message.destinationDomain, remoteDomain.toNumber(), "Invalid destination domain");
    assert.strictEqual(
      message.destinationCaller.toString(),
      new PublicKey(destinationCaller).toString(),
      "Invalid destinationCaller"
    );
    assert.strictEqual(message.minFinalityThreshold, minFinalityThreshold, "Invalid minFinalityThreshold");
    assert.strictEqual(message.messageBody.burnToken.toString(), burnToken.toString(), "Invalid burnToken");
    assert.strictEqual(
      message.messageBody.mintRecipient.toString(),
      new PublicKey(mintRecipient).toString(),
      "Invalid mintRecipient"
    );
    assert.strictEqual(message.messageBody.amount.toString(), burnAmount.toString(), "Invalid amount");
    assert.strictEqual(
      message.messageBody.messageSender.toString(),
      depositor.publicKey.toString(),
      "Invalid messageSender"
    );
    assert.strictEqual(message.messageBody.maxFee.toString(), maxFee.toString(), "Invalid maxFee");
    const expectedHookData = getHookDataFromQuote(quoteData);
    assert.isTrue(message.messageBody.hookData.equals(expectedHookData), "Invalid hookData");

    const usedNonceCloseInfo = await program.methods
      .getUsedNonceCloseInfo({ nonce: Array.from(nonce) })
      .accounts({ state })
      .view();
    assert.strictEqual(usedNonceCloseInfo.canCloseAfter.toString(), deadline.toString(), "Invalid canCloseAfter");
    assert.isFalse(usedNonceCloseInfo.canCloseNow, "Used nonce should not be closable now");
  });
});
