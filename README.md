![Across-logo](https://raw.githubusercontent.com/across-protocol/across-frontend/65abd7772704a9ec243fd370f9e8e76322f0905b/src/assets/logo.svg)

Contains smart contract suite to enable instant token transfers between any two networks. Relays are backstopped by
liquidity held in a central `HubPool` on Ethereum, which also serves as the cross-chain administrator of all contracts in the
system. `SpokePool` contracts are deployed to any network that wants to originate token deposits or be the final
destination for token transfers, and they are all governed by the `HubPool` on Ethereum.

These contracts have been continuously audited by OpenZeppelin and the audit reports can be found [here](https://docs.across.to/resources/audits).

## Understanding Upgradeability

The SpokePool contracts are [UUPSUpgradeable](https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/cbb66aca87521f818d9c1769c69d5dcc1004977a/contracts/proxy/utils/UUPSUpgradeable.sol) Proxy contracts which means that their addresses will always be the same but their implementation code can change.

All SpokePools can be upgraded if the "admin" of the contract calls `upgradeTo`. The SpokePool's admin is set by implementing the [`_requireAdminSender()` virtual function](https://github.com/across-protocol/contracts/blob/555475cdee6109afc85065ca415c740d7f97b992/contracts/SpokePool.sol#L1745) in the child contract. For example here are the [Arbitrum](https://github.com/across-protocol/contracts/blob/555475cdee6109afc85065ca415c740d7f97b992/contracts/Arbitrum_SpokePool.sol#L114) and [Optimism](https://github.com/across-protocol/contracts/blob/555475cdee6109afc85065ca415c740d7f97b992/contracts/Ovm_SpokePool.sol#L208) implementations of the admin check.

All SpokePools are implemented such that the admin is the HubPool, and therefore we describe the SpokePools as having "cross-chain ownership". The owner of the HubPool can call [this function](https://github.com/across-protocol/contracts/blob/555475cdee6109afc85065ca415c740d7f97b992/contracts/HubPool.sol#L249) to send a cross-chain execution of `upgradeTo` on any SpokePool in order to upgrade it.

This [script](https://github.com/across-protocol/contracts/blob/555475cdee6109afc85065ca415c740d7f97b992/tasks/upgradeSpokePool.ts) is useful for creating the calldata to execute a cross-chain upgrade via the HubPool.

## Deployed Contract Versions

The latest contract deployments can be found in `/deployments/deployments.json`.

## Requirements

This repository assumes you have [Node](https://nodejs.org/en/download/package-manager) installed, with a minimum version of 16.18.0. Depending on what you want to do with the repo you might also need [foundry](https://book.getfoundry.sh/getting-started/installation) and [anchor](https://www.anchor-lang.com/docs/installation) to also be installed. If you have build issues please ensure these are both installed first.

Note if you get build issues on the initial `yarn` command try downgrading to node 20.17 (`nvm use 20.17`). If you've never used anchor before you might need to run `avm use latest` as well.

## Build

```shell
yarn
yarn build # Will build all code. Compile solidity & rust (local toolchain), generate ts outputs
yarn build-verified # Will build all code. Compile solidity & rust (verified docker build), generate ts outputs
```

## Test

```shell
yarn test # Run all unit tests without gas analysis, using local toolchain SVM build
yarn test-verified # Run all unit tests (without gas analysis) with verified SVM docker build
yarn test:gas-analytics # Run only tests that count gas costs
yarn test:report-gas # Run unit tests with hardhat-gas-reporter enabled
yarn test-evm # Only test EVM code
yarn test-svm # Only test SVM code (local toolchain build)
yarn test-svm-solana-verify # Only test SVM code (verified docker build)
```

## Lint

```shell
yarn lint
yarn lint-js # Only lint Javascript
yarn lint-rust # Only lint rust
yarn lint-solidity # Only lint solidity
yarn lint-fix
```

## Deploy and Verify

### EVM

```shell
NODE_URL_1=https://mainnet.infura.com/xxx yarn hardhat deploy --tags HubPool --network mainnet
ETHERSCAN_API_KEY=XXX yarn hardhat etherscan-verify --network mainnet --license AGPL-3.0 --force-license --solc-input
```

### SVM

Before deploying for the first time make sure all program IDs in `lib.rs` and `Anchor.toml` are the same as listed when running `anchor keys list`. If not, update them to match the deployment keypairs under `target/deploy/` and commit the changes.

Make sure to use the verified docker binaries that can be built:

```shell
unset IS_TEST # Ensures the production build is used (not the test feature)
yarn build-svm-solana-verify # Builds verified SVM binaries
yarn generate-svm-artifacts # Builds IDLs
```

Export required environment variables, e.g.:

```shell
export RPC_URL=https://api.devnet.solana.com
export KEYPAIR=~/.config/solana/dev-wallet.json
export PROGRAM=svm_spoke # Also repeat the deployment process for multicall_handler
export PROGRAM_ID=$(cat target/idl/$PROGRAM.json | jq -r ".address")
export MULTISIG= # Export the Squads vault, not the multisig address!
export SOLANA_VERSION=$(grep -A 2 'name = "solana-program"' Cargo.lock | grep 'version' | head -n 1 | cut -d'"' -f2)
```

For the initial deployment also need these:

```shell
export SVM_CHAIN_ID=$(cast to-dec $(cast shr $(cast shl $(cast keccak solana-devnet) 208) 208))
export HUB_POOL=0x14224e63716afAcE30C9a417E0542281869f7d9e # This is for sepolia, update for mainnet
export DEPOSIT_QUOTE_TIME_BUFFER=3600
export FILL_DEADLINE_BUFFER=21600
export MAX_LEN=$(( 2 * $(stat -c %s target/deploy/$PROGRAM.so) )) # Reserve twice the size of the program for future upgrades
```

#### Initial deployment

Deploy the program and set the upgrade authority to the multisig:

```shell
solana program deploy \
  --url $RPC_URL \
  --keypair $KEYPAIR \
  --program-id target/deploy/$PROGRAM-keypair.json \
  --max-len $MAX_LEN \
  --with-compute-unit-price 50000 \
  --max-sign-attempts 100 \
  --use-rpc \
  target/deploy/$PROGRAM.so
solana program set-upgrade-authority \
  --url $RPC_URL \
  --keypair $KEYPAIR \
  --skip-new-upgrade-authority-signer-check \
  $PROGRAM_ID \
  --new-upgrade-authority $MULTISIG
```

Update and commit `deployments/deployments.json` with the deployed program ID and deployment slot.

Upload the IDL and set the upgrade authority to the multisig:

```shell
anchor idl init \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR \
  --filepath target/idl/$PROGRAM.json \
  $PROGRAM_ID
anchor idl set-authority \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR \
  --program-id $PROGRAM_ID \
  --new-authority $MULTISIG
```

`svm_spoke` also requires initialization and transfer of ownership on the first deployment:

```shell
anchor run initialize \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR -- \
  --chainId $SVM_CHAIN_ID \
  --remoteDomain 0 \
  --crossDomainAdmin $HUB_POOL \
  --svmAdmin $MULTISIG \
  --depositQuoteTimeBuffer $DEPOSIT_QUOTE_TIME_BUFFER \
  --fillDeadlineBuffer $FILL_DEADLINE_BUFFER
```

Create the vault for accepting deposits, e.g.:

```shell
export MINT=4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU # This is USDC on devnet, update with address for mainnet
anchor run createVault \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR -- \
  --originToken $MINT
```

#### Upgrades

Initiate the program upgrade:

```shell
solana program write-buffer \
  --url $RPC_URL \
  --keypair $KEYPAIR \
  --with-compute-unit-price 50000 \
  --max-sign-attempts 100 \
  --use-rpc \
  target/deploy/$PROGRAM.so
export BUFFER= # Export the logged buffer address from the command above
solana program set-buffer-authority \
  --url $RPC_URL \
  --keypair $KEYPAIR \
  $BUFFER \
  --new-buffer-authority $MULTISIG
```

Add the program ID to Squads multisig (`https://devnet.squads.so/` for devnet and `https://app.squads.so/` for mainnet) in the Developers/Programs section. Then add the upgrade filling in the buffer address and buffer refund. After creating the upgrade verify the buffer authority as prompted and proceed with initiating the upgrade. Once all required signers have approved, execute the upgrade in the transactions section.

Start the IDL upgrade by writing it to the buffer:

```shell
anchor idl write-buffer \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR \
  --filepath target/idl/$PROGRAM.json \
  $PROGRAM_ID
export IDL_BUFFER= # Export the logged IDL buffer address from the command above
anchor idl set-authority \
  --provider.cluster $RPC_URL \
  --provider.wallet $KEYPAIR \
  --program-id $PROGRAM_ID \
  --new-authority $MULTISIG \
  $IDL_BUFFER
```

Construct the multisig transaction for finalizing the IDL upgrade. Copy the printed base58 encoded transaction from below command and import it into the Squads multisig for approval and execution:

```shell
anchor run squadsIdlUpgrade -- \
  --programId $PROGRAM_ID \
  --idlBuffer $IDL_BUFFER \
  --multisig $MULTISIG \
  --closeRecipient $(solana address --keypair $KEYPAIR)
```

#### Verify

Start with verifying locally that the deployed program matches the source code of the public repository:

```shell
solana-verify verify-from-repo \
  --url $RPC_URL \
  --program-id $PROGRAM_ID \
   --library-name $PROGRAM \
   --base-image "solanafoundation/solana-verifiable-build:$SOLANA_VERSION" \
  https://github.com/across-protocol/contracts
```

When prompted, don't yet upload the verification data to the blockchain as that should be done by the multisig. Proceed with creating the upload transaction and then import and sign/execute it in the Squads multisig:

```shell
solana-verify export-pda-tx \
  --url $RPC_URL \
  --program-id $PROGRAM_ID \
  --library-name $PROGRAM  \
  --base-image "solanafoundation/solana-verifiable-build:$SOLANA_VERSION" \
  --uploader $MULTISIG \
  https://github.com/across-protocol/contracts
```

Note that the initial upload transaction might fail if the multisig vault does not have enough SOL for PDA creation. In that case, transfer the required funds to the multisig vault before executing the upload transaction.

Finally, submit the verification to OtterSec API (only works on mainnet):

```shell
solana-verify remote submit-job \
  --url $RPC_URL \
  --program-id $PROGRAM_ID \
  --uploader $MULTISIG
```

## Miscellaneous topics

### Manually Finalizing Scroll Claims from L2 -> L1 (Mainnet | Sepolia)

```shell
yarn hardhat finalize-scroll-claims --l2-address {operatorAddress}
```

### Slither

[Slither](https://github.com/crytic/slither) is a Solidity static analysis framework written in Python 3. It runs a
suite of vulnerability detectors, prints visual information about contract details, and provides an API to easily write
custom analyses. Slither enables developers to find vulnerabilities, enhance their code comprehension, and quickly
prototype custom analyses.

Spire-Contracts has been analyzed using `Slither@0.9.2` and no major bugs was found. To rerun the analytics, run:

```sh
slither contracts/SpokePool.sol
\ --solc-remaps @=node_modules/@
\ --solc-args "--optimize --optimize-runs 1000000"
\ --filter-paths "node_modules"
\ --exclude naming-convention
```

You can replace `SpokePool.sol` with the specific contract you want to analyze.

### ZK Sync Adapter

ZK EVM's typically require a special compiler to convert Solidity into code that can be run on the ZK VM.

There are special instructions for compiling and deploying contracts on `zksync`. The compile command will create `artifacts-zk` and `cache-zk` directories.

#### Compile

This step requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) to be running, as the `solc` docker image is fetched as a prerequisite.

`yarn compile-zksync`

## License

All code in this repository is licensed under BUSL-1.1 unless specified differently in the file.
Individual exceptions to this license can be made by Risk Labs, which holds the rights to this
software and design. If you are interested in using the code or designs in a derivative work,
feel free to reach out to licensing@risklabs.foundation.
