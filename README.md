![Across-logo](https://raw.githubusercontent.com/across-protocol/across-frontend/65abd7772704a9ec243fd370f9e8e76322f0905b/src/assets/logo.svg)

Contains smart contract suite to enable instant token transfers between any two networks. Relays are backstopped by
liquidity held in a central `HubPool` on Ethereum, which also serves as the cross-chain administrator of all contracts in the
system. `SpokePool` contracts are deployed to any network that wants to originate token deposits or be the final
destination for token transfers, and they are all governed by the `HubPool` on Ethereum.

This contract set is the second iteration of the [Across smart contracts](https://github.com/across-protocol/across-smart-contracts)
which facilitates token transfers from any L2 to L1.

These contracts were [audited by OpenZeppelin](https://blog.openzeppelin.com/uma-across-v2-audit/) which is a great resource for understanding the contracts.

[This video](https://www.youtube.com/watch?v=iuxf6Crv8MI) is also useful for understanding the technical architecture.

## Deployed Contract Versions

The latest contract deployments on Production will always be under the `deployed` tag.

## Build

```shell
yarn
yarn hardhat compile
```

## Test

```shell
yarn test # Run unit tests without gas analysis
yarn test:gas-analytics # Run only tests that count gas costs
yarn test:report-gas # Run unit tests with hardhat-gas-reporter enabled
```

## Lint

```shell
yarn lint
yarn lint-fix
```

## Deploy and Verify

```shell
NODE_URL_1=https://mainnet.infura.com/xxx yarn hardhat deploy --tags HubPool --network mainnet
ETHERSCAN_API_KEY=XXX yarn hardhat etherscan-verify --network mainnet --license AGPL-3.0 --force-license --solc-input
```

## Tasks

##### Finalize Scroll Claims from L2 -> L1 (Mainnet | Sepolia)

```shell
yarn hardhat finalize-scroll-claims --l2-address {operatorAddress}
```

## Slither

[Slither](https://github.com/crytic/slither) is a Solidity static analysis framework written in Python 3. It runs a
suite of vulnerability detectors, prints visual information about contract details, and provides an API to easily write
custom analyses. Slither enables developers to find vulnerabilities, enhance their code comprehension, and quickly
prototype custom analyses.

Spire-Contracts have been analyzed using `Slither@0.9.2` and no major bugs were found. To rerun the analytics, run:

```sh
slither contracts/SpokePool.sol
\ --solc-remaps @=node_modules/@
\ --solc-args "--optimize --optimize-runs 1000000"
\ --filter-paths "node_modules"
\ --exclude naming-convention
```

You can replace `SpokePool.sol` with the specific contract you want to analyze.

## ZK Sync Adapter

These are special instructions for compiling and deploying contracts on `zksync`. The compile command will create `artifacts-zk` and `cache-zk` directories.

### Compile

This step requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) to be running, as the `solc` docker image is fetched as a prerequisite.

`yarn compile-zksync`

## License

All code in this repository is licensed under BUSL-1.1 unless specified differently in the file.
Individual exceptions to this license can be made by Risk Labs, which holds the rights to this
software and design. If you are interested in using the code or designs in a derivative work,
feel free to reach out to licensing@risklabs.foundation.
