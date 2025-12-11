### Deployment process. It's IMPORTANT to perform all steps, otherwise funds WILL get lost

0. **Deploy all wanted Src periphery contracts**

See `./DeploySrcPeriphery.s.sol` for commands

1. **Run deployment script**

```
forge script script/mintburn/oft/DeployDstHandler.s.sol:DeployDstOFTHandler \
  --sig "run(string)" usdt0 \
  --rpc-url hyperevm -vvvv --broadcast --verify
```

Make sure all the src peripheries are correctly configured (currently addrs for this config are taken from usdt0.toml)

2. **Configure baseToken**
   Example with cast for USDT0:

```
cast send $DEPLOYED_DST_OFT "setCoreTokenInfo(address,uint32,bool,uint64,uint64)" 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb 268 true 100000000 100000000000000 --rpc-url hyperevm --account dev
```

2.(a) Configure additional tokens, like USDC:

CoreTokenInfo:

```
cast send $DEPLOYED_DST_OFT "setCoreTokenInfo(address,uint32,bool,uint64,uint64)" 0xb88339CB7199b77E23DB6E890353E22632Ba630f 0 true 100000000 100000000000000 --rpc-url hyperevm --account dev
```

(before adding FinalTokenInfo):

predict SwapHandler address:

cast parse-bytes32-address $(cast call $DEPLOYED_DST_OFT "predictSwapHandler(address)" 0xb88339CB7199b77E23DB6E890353E22632Ba630f --rpc-url hyperevm)

Activate HyperLiquid account for that (see step 3 for an example).

And FinalTokenInfo:

```
cast send $DEPLOYED_DST_OFT "setFinalTokenInfo(address,uint32,bool,uint32,uint32,address)" 0xb88339CB7199b77E23DB6E890353E22632Ba630f 166 false 140 2 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb --rpc-url hyperevm --account dev
```

3. **Activate $DEPLOYED_DST_OFT account on HyperCore**

Go to Hyperliquid UI and set 1 wei of USDC to it. Check activation status with:

```
curl -s https://api.hyperliquid.xyz/info \
  -H 'content-type: application/json' \
  -d "{\"type\":\"userRole\",\"user\":\"$DEPLOYED_DST_OFT\"}"
```

You want to see `{"role":"user"}%` as a response. That means that the account was activated. Otherwise, would say `{"role":"missing"}%`

4. Transfer ownership to multisig / trusted account / renounce ownership of DstOftHandler. TODO: could be enabled in the script if we could set core token info from there ... Foundry doesn't let us interact with precompiles from scripts (can't skip sim)

5. Test that the baseToken + core accounts are functioning correctly by calling the `CreateSponsoredDeposit` script and waiting for tokens to show up on the Hyperliquid balance of the dev wallet.

```
forge script script/mintburn/oft/CreateSponsoredDeposit.s.sol:CreateSponsoredDeposit \
  --sig "run(string,uint256,uint256)" usdt0 1000000 100 --rpc-url arbitrum -vvvv --broadcast
```

### Misc

Grant `PERMISSIONED_BOT_ROLE`:

```
cast send $DEPLOYED_DST_OFT "grantRole(bytes32,address)" 0x5300fde95a5e446527bf6aa7c91bd6661bef5398afc77061d9bc87efb80b7ef6 $ROLE_RECIPIENT --rpc-url hyperevm --account dev
```

Open orders for an `ADDR`:

```
ADDR=0xe199ce8af95937e3a0c61d437b0cbf2481c81c8c
curl -s https://api.hyperliquid.xyz/info \
  -H 'content-type: application/json' \
  -d "{\"type\":\"openOrders\",\"user\":\"$ADDR\"}"
```

Spot balances for an addr:

```
curl -s https://api.hyperliquid.xyz/info \
  -H 'content-type: application/json' \
  -d "{\"type\":\"spotClearinghouseState\",\"user\":\"$ADDR\"}"
```

Activate user account:

```
cast send $DEPLOYED_DST_OFT "activateUserAccount(bytes32,address,address)" 0x00000000000000000000000000000000000000000000000000000000690D6445 0x67C6Cf5288E5D8Bc474126949B3A50Cfe5512AF9 0xb8ce59fc3717ada4c02eadf9682a9e934f625ebb --rpc-url hyperevm --account dev
```

Calculations + limit order submission:

Calc size based on coreIn + price

```
forge script script/mintburn/LimitOrderCalcCli.s.sol:LimitOrderCalcCli \
  --sig "calcLOAmounts(uint64,uint64,bool,uint64,uint8,uint8,uint8,uint8)" \
  1033000000 99970000 false 140 8 2 8 8
```

Submit Limit order:

```
cast send $DEPLOYED_DST_OFT "submitLimitOrderFromBot(address,uint64,uint64,uint128)" 0xb88339CB7199b77E23DB6E890353E22632Ba630f 99990000 100000000 1 --rpc-url hyperevm --account dev
```

Finalize a swap flow:

```
cast send $DEPLOYED_DST_OFT "finalizeSwapFlows(address,bytes32[],uint64[])" 0xb88339CB7199b77E23DB6E890353E22632Ba630f "[0x00000000000000000000000000000000000000000000000000000000690D3DBE]" "[122576511]" --rpc-url hyperevm --account dev
```
