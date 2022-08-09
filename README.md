![Across-logo](https://raw.githubusercontent.com/across-protocol/across-frontend/65abd7772704a9ec243fd370f9e8e76322f0905b/src/assets/logo.svg)

Contains smart contract suite to enable instant token transfers between any two networks. Relays are backstopped by
liquidity held in a central `HubPool` on Ethereum, which also serves as the cross-chain administrator of all contracts in the
system. `SpokePool` contracts are deployed to any network that wants to originate token deposits or be the final
destination for token transfers, and they are all governed by the `HubPool` on Ethereum.

This contract set is the second iteration of the [Across smart contracts](https://github.com/across-protocol/across-smart-contracts)
which facilitate token transfers from any L2 to L1.

These contracts were [audited by OpenZeppelin](https://blog.openzeppelin.com/uma-across-v2-audit/) which is a great resource for understanding the contracts.

[This video](https://www.youtube.com/watch?v=iuxf6Crv8MI) is also useful for understanding the technical architecture.

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

## ZK Sync Adapter

`zksync` does not plug cleanly into `hardhat-deploy` so there are special instructions for compiling and deploying contracts on `zksync`. The compile command will create `artifacts-zk` and `cache-zk` directories.

### Compile

This step requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) to be running, as the `solc` docked image is fetched as a prerequisite.

`yarn compile-zksync`

### Deploy

`yarn hardhat deploy-zksync --script 016_deploy_zksync_spokepool.ts --network zksync-goerli`
