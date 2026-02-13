## Hypercore token metadata notes

- To get `hypercore-tokens.json` info:

```
curl -s 'https://api.hyperliquid.xyz/info' \
  -H 'content-type: application/json' \
  --data '{"type":"spotMeta"}' \
| jq '.tokens[]
      | select((.name|ascii_upcase)=="USDT0"
            or (.name|ascii_upcase)=="USDC"
            or (.name|ascii_upcase)=="USDH")'
```

These 3 fields added manually to each entry:

```
    "canBeUsedForAccountActivation": true,
    "accountActivationFeeCore": 100000000,
    "bridgeSafetyBufferCore": 100000000000000000
```

- `script/mintburn/hypercore-tokens.json` is read by `script/mintburn/ReadHCoreTokenInfoUtil.s.sol`.
- USDC is a special case: `evmContract.address` in that JSON is **not** the real HyperEVM USDC ERC20 address.
- Read utils hard-override USDC to `0xb88339CB7199b77E23DB6E890353E22632Ba630f` for all script configuration paths.
- Same address is documented in `script/mintburn/oft/README.md`.
