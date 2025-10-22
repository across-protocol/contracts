import * as anchor from "@coral-xyz/anchor";
import { BN, Program, workspace } from "@coral-xyz/anchor";
import { createMint, getOrCreateAssociatedTokenAccount, mintTo, TOKEN_PROGRAM_ID, getAccount } from "@solana/spl-token";
import {
  AddressLookupTableAccount,
  AddressLookupTableProgram,
  Keypair,
  PublicKey,
  sendAndConfirmTransaction,
  SendTransactionError,
  SystemProgram,
  Transaction,
} from "@solana/web3.js";
import { assert } from "chai";
import * as crypto from "crypto";
import { ethers } from "ethers";
import { TokenMessengerMinterV2 } from "../../target/types/token_messenger_minter_v2";
import { MessageTransmitterV2 } from "../../src/svm/assets/message_transmitter_v2";
import { program, provider, connection, initializeState, owner, createQuoteSigner } from "./SponsoredCctpSrc.common";
import { SponsoredCCTPQuote, HookData } from "./SponsoredCctpSrc.types";
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
  const operator = Keypair.generate();
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
  const maxUserSlippageBps = 1000;
  const executionMode = 0; // DirectToCore
  const actionData = "0x"; // Empty in DirectToCore mode

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

  const signSponsoredCCTPQuote = (signer: ethers.Wallet, quoteData: SponsoredCCTPQuote): Buffer => {
    const encodedPart1 = ethers.utils.defaultAbiCoder.encode(
      ["uint32", "uint32", "bytes32", "uint256", "bytes32", "bytes32", "uint256", "uint32"],
      [
        quoteData.sourceDomain,
        quoteData.destinationDomain,
        quoteData.mintRecipient,
        quoteData.amount,
        quoteData.burnToken,
        quoteData.destinationCaller,
        quoteData.maxFee,
        quoteData.minFinalityThreshold,
      ]
    );
    const encodedPart2 = ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "uint256", "uint256", "uint256", "bytes32", "bytes32", "uint8", "bytes32"],
      [
        quoteData.nonce,
        quoteData.deadline,
        quoteData.maxBpsToSponsor,
        quoteData.maxUserSlippageBps,
        quoteData.finalRecipient,
        quoteData.finalToken,
        quoteData.executionMode,
        ethers.utils.keccak256(quoteData.actionData),
      ]
    );
    const hash1 = ethers.utils.keccak256(encodedPart1);
    const hash2 = ethers.utils.keccak256(encodedPart2);
    const encodedHexString = ethers.utils.defaultAbiCoder.encode(["bytes32", "bytes32"], [hash1, hash2]);
    const digest = ethers.utils.keccak256(encodedHexString);

    // Create simple ECDSA signature over the encoded quote data hash.
    const signatureHexString = ethers.utils.joinSignature(signer._signingKey().signDigest(digest));
    return Buffer.from(ethers.utils.arrayify(signatureHexString));
  };

  const getEncodedQuoteWithSignature = (
    signer: ethers.Wallet,
    quoteData: SponsoredCCTPQuote
  ): { quote: Buffer; signature: Buffer } => {
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
        "uint256",
        "bytes32",
        "bytes32",
        "uint8",
        "bytes",
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
        quoteData.maxUserSlippageBps,
        quoteData.finalRecipient,
        quoteData.finalToken,
        quoteData.executionMode,
        quoteData.actionData,
      ]
    );
    const encodedQuote = Buffer.from(ethers.utils.arrayify(encodedHexString));

    const signature = signSponsoredCCTPQuote(signer, quoteData);

    return { quote: encodedQuote, signature };
  };

  const getHookDataFromQuote = (quoteData: SponsoredCCTPQuote): Buffer => {
    const encodedHexString = ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "uint256", "uint256", "uint256", "bytes32", "bytes32", "uint8", "bytes"],
      [
        quoteData.nonce,
        quoteData.deadline,
        quoteData.maxBpsToSponsor,
        quoteData.maxUserSlippageBps,
        quoteData.finalRecipient,
        quoteData.finalToken,
        quoteData.executionMode,
        quoteData.actionData,
      ]
    );

    return Buffer.from(ethers.utils.arrayify(encodedHexString));
  };

  const decodeHookData = (data: Buffer | Uint8Array | string): HookData => {
    const ABI_TYPES = [
      "bytes32", // nonce
      "uint256", // deadline
      "uint256", // maxBpsToSponsor
      "uint256", // maxUserSlippageBps
      "bytes32", // finalRecipient
      "bytes32", // finalToken
      "uint8", // executionMode
      "bytes", // actionData
    ] as const;

    const decoded = ethers.utils.defaultAbiCoder.decode(ABI_TYPES, data);

    const [
      nonce,
      deadline,
      maxBpsToSponsor,
      maxUserSlippageBps,
      finalRecipient,
      finalToken,
      executionMode,
      actionData,
    ] = decoded as [string, ethers.BigNumber, ethers.BigNumber, ethers.BigNumber, string, string, number, string];

    return {
      nonce,
      deadline,
      maxBpsToSponsor,
      maxUserSlippageBps,
      finalRecipient,
      finalToken,
      executionMode,
      actionData,
    };
  };

  const setupBurnToken = async () => {
    burnToken = await createMint(connection, payer, owner, owner, tokenDecimals, undefined, undefined, tokenProgram);

    depositorTokenAccount = (
      await getOrCreateAssociatedTokenAccount(
        connection,
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
      connection,
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
      recentSlot: await connection.getSlot(),
    });

    // Submit the ALT creation transaction
    await sendAndConfirmTransaction(connection, new Transaction().add(lookupTableInstruction), [payer], {
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

    await sendAndConfirmTransaction(connection, new Transaction().add(extendInstruction), [payer], {
      commitment: "confirmed",
      skipPreflight: true,
    });

    // Wait for slot to advance. ALTs only active after slot advance.
    const initialSlot = await connection.getSlot();
    while ((await connection.getSlot()) === initialSlot) {
      await new Promise((resolve) => setTimeout(resolve, 50));
    }

    // Fetch the AddressLookupTableAccount.
    const fetchedLookupTableAccount = (await connection.getAddressLookupTable(lookupTableAddress)).value;
    if (fetchedLookupTableAccount === null) throw new Error("AddressLookupTableAccount not fetched");
    lookupTableAccount = fetchedLookupTableAccount;
  };

  const setupRentFund = async () => {
    rentFund = findProgramAddress("rent_fund", program.programId).publicKey;
    await connection.requestAirdrop(rentFund, 1_000_000_000); // 1 SOL
  };

  const getUsedNonce = (nonce: Buffer): PublicKey => {
    const [usedNonce] = PublicKey.findProgramAddressSync([Buffer.from("used_nonce"), nonce], program.programId);
    return usedNonce;
  };

  before(async () => {
    await connection.requestAirdrop(depositor.publicKey, 10_000_000_000); // 10 SOL
    await connection.requestAirdrop(operator.publicKey, 10_000_000_000); // 10 SOL

    setupCctpAccounts();

    await setupRentFund();

    ({ state, sourceDomain } = await initializeState({ signer: quoteSignerPubkey }));

    tokenProgram = TOKEN_PROGRAM_ID;
    await setupBurnToken();
    await setupLookupTable();
  });

  beforeEach(async () => {
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
      maxUserSlippageBps,
      finalRecipient: ethers.utils.hexlify(finalRecipient),
      finalToken: ethers.utils.hexlify(finalToken),
      executionMode,
      actionData,
    };
    const { quote, signature } = getEncodedQuoteWithSignature(quoteSigner, quoteData);

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
      connection,
      [depositIx],
      lookupTableAccount,
      depositor,
      [messageSentEventData]
    );

    const depositorTokenAmount = (await getAccount(connection, depositorTokenAccount)).amount;
    const expectedDepositorTokenAmount = seedBalance - BigInt(burnAmount.toString());
    assert.strictEqual(
      depositorTokenAmount.toString(),
      expectedDepositorTokenAmount.toString(),
      "Depositor token amount mismatch"
    );

    const events = await readEventsUntilFound(connection, txSignature, [program]);

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
    assert.strictEqual(
      depositEvent.maxUserSlippageBps.toString(),
      maxUserSlippageBps.toString(),
      "Invalid maxUserSlippageBps"
    );
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

    const usedNonceCloseInfo = await program.methods.getUsedNonceCloseInfo({ nonce: Array.from(nonce) }).view();
    assert.strictEqual(usedNonceCloseInfo.canCloseAfter.toString(), deadline.toString(), "Invalid canCloseAfter");
    assert.isFalse(usedNonceCloseInfo.canCloseNow, "Used nonce should not be closable now");
  });

  it("Reclaim used_nonce account", async () => {
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
      maxUserSlippageBps,
      finalRecipient: ethers.utils.hexlify(finalRecipient),
      finalToken: ethers.utils.hexlify(finalToken),
      executionMode,
      actionData,
    };
    const { quote, signature } = getEncodedQuoteWithSignature(quoteSigner, quoteData);

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
    await sendTransactionWithExistingLookupTable(connection, [depositIx], lookupTableAccount, depositor, [
      messageSentEventData,
    ]);

    const reclaimIx = await program.methods
      .reclaimUsedNonceAccount({ nonce: Array.from(nonce) })
      .accountsPartial({ usedNonce })
      .instruction();

    try {
      await sendAndConfirmTransaction(connection, new Transaction().add(reclaimIx), [operator]);
      assert.fail("Reclaim used nonce account should have failed");
    } catch (err: any) {
      assert.instanceOf(err, SendTransactionError);
      const logs = await (err as SendTransactionError).getLogs(connection);
      assert.isTrue(
        logs.some((log) => log.includes("QuoteDeadlineNotPassed")),
        "Expected QuoteDeadlineNotPassed error log"
      );
    }

    const usedNonceLamports = await connection.getBalance(usedNonce);
    const rentFundLamportsBefore = await connection.getBalance(rentFund);

    await program.methods.setCurrentTime({ newTime: new BN(deadline.add(1).toString()) }).rpc();

    await sendAndConfirmTransaction(connection, new Transaction().add(reclaimIx), [operator]);

    try {
      await program.account.usedNonce.fetch(usedNonce);
      assert.fail("Fetching closed account should have failed");
    } catch (err: any) {
      assert.instanceOf(err, Error);
      assert.include((err as Error).message, "Account does not exist", "Expected account not found error");
    }

    const rentFundLamportsAfter = await connection.getBalance(rentFund);
    assert.strictEqual(
      rentFundLamportsAfter,
      rentFundLamportsBefore + usedNonceLamports,
      "Rent fund should receive all lamports from reclaimed used nonce account"
    );
  });

  it("Reclaim used_nonce account", async () => {
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
      maxUserSlippageBps,
      finalRecipient: ethers.utils.hexlify(finalRecipient),
      finalToken: ethers.utils.hexlify(finalToken),
      executionMode,
      actionData,
    };
    const { quote, signature } = getEncodedQuoteWithSignature(quoteSigner, quoteData);

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
    await sendTransactionWithExistingLookupTable(connection, [depositIx], lookupTableAccount, depositor, [
      messageSentEventData,
    ]);

    const reclaimIx = await program.methods
      .reclaimUsedNonceAccount({ nonce: Array.from(nonce) })
      .accountsPartial({ usedNonce })
      .instruction();

    try {
      await sendAndConfirmTransaction(connection, new Transaction().add(reclaimIx), [operator]);
      assert.fail("Reclaim used nonce account should have failed");
    } catch (err: any) {
      assert.instanceOf(err, SendTransactionError);
      const logs = await (err as SendTransactionError).getLogs(connection);
      assert.isTrue(
        logs.some((log) => log.includes("QuoteDeadlineNotPassed")),
        "Expected QuoteDeadlineNotPassed error log"
      );
    }

    const usedNonceLamports = await connection.getBalance(usedNonce);
    const rentFundLamportsBefore = await connection.getBalance(rentFund);

    await program.methods.setCurrentTime({ newTime: new BN(deadline.add(1).toString()) }).rpc();

    await sendAndConfirmTransaction(connection, new Transaction().add(reclaimIx), [operator]);

    try {
      await program.account.usedNonce.fetch(usedNonce);
      assert.fail("Fetching closed account should have failed");
    } catch (err: any) {
      assert.instanceOf(err, Error);
      assert.include((err as Error).message, "Account does not exist", "Expected account not found error");
    }

    const rentFundLamportsAfter = await connection.getBalance(rentFund);
    assert.strictEqual(
      rentFundLamportsAfter,
      rentFundLamportsBefore + usedNonceLamports,
      "Rent fund should receive all lamports from reclaimed used nonce account"
    );
  });

  it("Deposit with maximum actionData length", async () => {
    const nonce = crypto.randomBytes(32);
    const usedNonce = getUsedNonce(nonce);
    const deadline = ethers.BigNumber.from(Math.floor(Date.now() / 1000) + 3600);
    const executionMode = 1; // ArbitraryActionsToCore
    const actionDataLenth = 128; // Larger actionData would exceed the transaction message size limits on Solana.
    const actionData = crypto.randomBytes(actionDataLenth);

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
      maxUserSlippageBps,
      finalRecipient: ethers.utils.hexlify(finalRecipient),
      finalToken: ethers.utils.hexlify(finalToken),
      executionMode,
      actionData: ethers.utils.hexlify(actionData),
    };
    const { quote, signature } = getEncodedQuoteWithSignature(quoteSigner, quoteData);

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
    await sendTransactionWithExistingLookupTable(connection, [depositIx], lookupTableAccount, depositor, [
      messageSentEventData,
    ]);

    const message = decodeMessageSentDataV2(
      (await messageTransmitterV2Program.account.messageSent.fetch(messageSentEventData.publicKey)).message
    );
    const expectedHookData = getHookDataFromQuote(quoteData);
    assert.isTrue(message.messageBody.hookData.equals(expectedHookData), "Invalid hookData");

    // Above check for encoded hookData should implicitly verify action data, but add explicit test for clarity.
    const decodedHookData = decodeHookData(message.messageBody.hookData);
    assert.strictEqual(decodedHookData.actionData, ethers.utils.hexlify(actionData), "Invalid actionData");
  });
});
