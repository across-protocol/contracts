# Solana operational scripts

CCTP operational scripts use CCTP V2 with Anchor / `@solana/web3.js` v1. Solana is a light chain: HubPool/spoke liquidity rebalances are unsupported, and intents involving Solana repay relayers on the deposit's origin chain. Tokenless root/admin messages still travel from Ethereum to the spoke over CCTP.

## Prerequisites

Install dependencies with `yarn install --frozen-lockfile`, build with `yarn build-svm`, and generate current IDLs/types with `yarn generate-svm-artifacts`. Use the Anchor version matching the programs (0.31.1). Also run `yarn build-evm-foundry` for the pause and sponsored scripts, which import shared EVM helpers.

Set `ANCHOR_PROVIDER_URL` to the desired Solana RPC and `ANCHOR_WALLET` to a funded Solana keypair file, or supply Anchor's `--provider.cluster` and `--provider.wallet` options. The existing network resolver expects `devnet` or `mainnet` in the RPC URL; it selects the corresponding deployed program IDs and Circle Iris endpoint. Use the upgraded CCTP V2 spoke deployment. The production state seed is `0`.

## Finalize an existing root/admin message or token transfer

```sh
anchor run finalizeCctpV2Message -- \
  --sourceTx 0x_SOURCE_EVM_TRANSACTION_HASH \
  --seed 0
```

This requires a Solana fee/rent payer and access to Circle Iris. It does not require an EVM RPC, mnemonic or HubPool signing authority. The source CCTP domain defaults to the selected spoke's state; use `--sourceDomain` for a token transfer from another CCTP domain.

The script waits for V2 attestations and selects the receiver from the attested header. Messages addressed to the selected Solana spoke use accounts for every call its receiver supports:

- `pauseDeposits(bool)` and `pauseFills(bool)`.
- `setCrossDomainAdmin(address)`.
- `relayRootBundle(bytes32,bytes32)`, using the current next root-bundle ID.
- `emergencyDeleteRootBundle(uint256)`, using the ID in the message.

Spoke messages must have finalized attestations (threshold at least 2000) and match the spoke's remote domain/admin. The script decodes finality from message bytes and ignores Iris's optional decoded metadata. A permissioned `destinationCaller` must match the Solana wallet for either receiver.

Messages addressed to Circle's TokenMessengerMinterV2 use a separate token account builder. It reads `TokenPair.localToken` as the LocalToken account address, then reads its mint/custody and the TokenMessenger fee recipient. Token delivery supports both finalized and unfinalized attestations, subject to Circle's on-chain checks. The destination receives `amount - feeExecuted`.

By default, the attested `mintRecipient` must equal the selected spoke's vault ATA for that mint. To finalize an independent inventory transfer, explicitly select its destination **token account**, not its wallet owner:

```sh
anchor run finalizeCctpV2Message -- \
  --sourceTx 0x_SOURCE_EVM_TRANSACTION_HASH \
  --sourceDomain 0 \
  --tokenRecipient SOLANA_DESTINATION_TOKEN_ACCOUNT
```

This option checks the attested destination; it cannot redirect tokens. The destination and Circle fee-recipient token accounts must already exist. With an explicit source domain and token recipient, token delivery does not require reading spoke state. This is manual delivery of an existing burn, not a HubPool rebalance workflow.

Polling stops after 120 seconds by default; use `--timeoutSeconds 600` for a longer wait. A missing or pending attestation does not cause another source transaction. Rerun with the same `--sourceTx` after a timeout, RPC error or interrupted process. Confirmed used-nonce accounts produce `already processed`, including for messages that changed the remote admin or created/deleted a root bundle. Errors other than an already-used nonce remain errors.

If a transaction contains multiple matching messages, including a mix of Spoke and TokenMessenger messages, the script lists their nonces and requires `--nonce <decimal-or-0x-attested-nonce>` before submitting anything. Inspect the source transaction and deliver them individually in the intended order; Iris response order is not used to infer admin/root execution order. Token-recipient validation happens after nonce selection. The script waits for the transaction's V2 attestations before selecting a nonce. Do not run competing root-message finalizations; if the next root ID changes concurrently, rerun the failed message to rebuild accounts.

## Send a pause/resume message

For a HubPool-owned spoke:

```sh
anchor run remoteHubPoolPauseDeposits -- --chainId SOLANA_CHAIN_ID --pause true
anchor run remoteHubPoolPauseDeposits -- --chainId SOLANA_CHAIN_ID --pause false
```

Sending requires `MNEMONIC`, `HUB_POOL_ADDRESS` and `NODE_URL_1` (mainnet) or `NODE_URL_11155111` (Sepolia/devnet). The EVM signer must be authorized to call HubPool. The adapter must already route tokenless messages through CCTP V2. The script checks the EVM network, spoke chain ID and configured cross-domain admin before sending.

For a test spoke whose cross-domain admin is the EVM wallet itself:

```sh
anchor run remotePauseDeposits -- --seed 0 --pause true
```

This requires `MNEMONIC` and the matching `NODE_URL_*`. Both scripts print the source transaction hash before waiting for confirmation, then use the shared V2 finalizer with only the Spoke receiver enabled. For recovery, replace `--pause` with `--resumeRemoteTx 0x_SOURCE_HASH`, or use `finalizeCctpV2Message`. Recovery needs no EVM credentials or RPC. `--pause` and `--resumeRemoteTx` are mutually exclusive.

## Intent examples and retained token transfers

`simpleFill` and `fakeFillWithRandomDistribution` use `originChainId` as the repayment chain, including when deriving the fill delegate PDA. Both require `--repaymentAddress` for that origin chain (EVM hex or Solana base58); it is separate from the Solana transaction signer. The arbitrary `--repaymentChain` option has been removed from the random-distribution example.

`simpleFakeRelayerRepayment` remains a test fixture: it deposits local tokens, creates a synthetic refund root and repays on Solana with `amountToReturn = 0`. It needs local spoke admin authority and is not a production bundle-construction script.

The old `proposeRebalanceToSpokePool` / `executeRebalanceToSpokePool` commands and their token-rebalance tree helper are removed. Independent token transfers remain supported: `SponsoredCctpSrc/*` already uses V2 and still provides deposit-for-burn, EVM receive, event-account reclamation and nonce/rent operations. This migration does not replace those flows with tokenless finalization.

## Validation and release handoff

`test/svm/Scripts.CctpV2.ts` covers attestation polling and error handling without public transactions. `test/svm/SvmSpoke.HandleReceiveMessage.ts` exercises the shared script finalizer against the local validator and CCTP V2 program, including root/admin calls, already-delivered messages and failed-message recovery. Run these with the repository's SVM suite (`yarn test-svm`); the attestation tests can also run alone with `yarn ts-mocha -p tsconfig.json -t 10000 test/svm/Scripts.CctpV2.ts`.

`test/svm/Scripts.CctpV2Tokens.ts` covers the token receiver against Circle's local programs: fee deductions, finalized/unfinalized thresholds, expected recipient enforcement, used-nonce recovery and retry after on-chain rejection. The three focused suites passed together (29 tests) after adding token delivery and finality-boundary coverage.

Public-network end-to-end validation is still outstanding: send and finalize a tokenless pause and root message against an upgraded test deployment, interrupt and resume delivery, confirm the HubPool/adapter route, and finalize an independent token transfer. Local fixtures bypass Circle signature verification; they do not validate production attestations or deployed configuration.

See [SVM_TS_PLAN.md](../../SVM_TS_PLAN.md) for the consumer migration and later export removal. Publish a reviewed contracts beta with the regenerated Spoke IDL/client and matching test artifacts for step 2. Existing V1/V2 client exports remain until consumers migrate; no new production helpers are exported from these scripts.
