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
yarn build # Will build all code. Compile solidity & rust, generate ts outputs
```

## Test

```shell
yarn test # Run all unit tests without gas analysis
yarn test:gas-analytics # Run only tests that count gas costs
yarn test:report-gas # Run unit tests with hardhat-gas-reporter enabled
yarn test-evm # Only test EVM code
yarn test-svm # Only test SVM code
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

```shell
NODE_URL_1=https://mainnet.infura.com/xxx yarn hardhat deploy --tags HubPool --network mainnet
ETHERSCAN_API_KEY=XXX yarn hardhat etherscan-verify --network mainnet --license AGPL-3.0 --force-license --solc-input
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
