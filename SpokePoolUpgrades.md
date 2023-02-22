# An Overview of how SpokePools would be upgraded

## Before executing upgrade

To be safe, make sure there is no pending bundle in the HubPool. To be extra safe, disable every single deposit route
and only re-enable them after executing the upgrade. This is probably over-cautious when upgrading via proxy but
definitely should be done when upgrading without a proxy.

## When upgrading via proxy:

1. Deploy new SpokePool implementation contract on L2.
2. Call `upgradeTo` on existing SpokePool proxy with new implementation address. The existing state should carry over
   and the system should just work.

## When upgrading without a proxy:

If SpokePool is not an upgradeable proxy, then upgrading is more involved.

1. Deploy new SpokePool contract.
2. Get function calldata for the following calls that we'll send to the HubPool:

   a. `setCrossChainContracts(uint256 chainId,address existingAdapter,address newL2SpokePoolAddress)`
   b. `setDepositRoute(uint256 fromChain,uint256 toChain,address originChain)`: This needs to be added to and from every other chain that exists in the system. For example, if we're upgrading the SpokePool on chain 10, then we need to add calldata for all chains to 10 and 10 to all chains.
   c. If we're upgrading the Arbitrum spoke pool, then add `whitelistToken(address arbitrumToken,address l1Token)`.
   d. If we're upgrading Optimism spoke pool, need to add `setTokenBridge(address l2Token,address customBridge)` for any tokens with custom bridges like DAI and SNX on Optimism.

3. Each of the above calldata's needs to be loaded into a HubPool call to `relaySpokePoolAdminFunction(uint256 chainId,bytes calldata)`.
4. Add all of the transactions (i.e. each of the `relaySpokePoolAdminFunctions`) into an atomic transaction that is executed to finalize the "upgrade".

## Addendum:

### Adding new tokens to SpokePools

This process has some overlap with upgrading spoke pools in that each new spoke pool address needs to be aware of other L2 chains and tokens that it can have deposit paths to/from.

Adding new tokens is enabled mostly via the script [enableL1TokenAcrossEcosystem.ts](./tasks/enableL1TokenAcrossEcosystem.ts).
