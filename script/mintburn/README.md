# Mintburn Prod Readiness Checks

`checkSponsoredPeripheryProdReadiness.sh` checks the latest canonical sponsored mintburn periphery deployments from [`broadcast/deployed-addresses.json`](/Users/dev/dev/contracts2/broadcast/deployed-addresses.json).

[`hypercore-tokens.json`](/Users/dev/dev/contracts2/script/mintburn/hypercore-tokens.json) lives alongside these scripts and is read by [`ReadHCoreTokenInfoUtil.s.sol`](/Users/dev/dev/contracts2/script/mintburn/ReadHCoreTokenInfoUtil.s.sol) for HyperCore token setup.

Run it with:

```bash
./script/mintburn/checkSponsoredPeripheryProdReadiness.sh --dev-wallet 0xYourDevWallet
./script/mintburn/checkSponsoredPeripheryProdReadiness.sh --dev-wallet 0xYourDevWallet --full
./script/mintburn/checkSponsoredPeripheryProdReadiness.sh --dev-wallet 0xYourDevWallet --multisigs-file script/mintburn/prod-readiness-multisigs.json
```

The script reads RPC URLs from exported `NODE_URL_<chainId>` env vars. If a `.env` file exists at the repository root, it is loaded automatically.

Per-chain multisigs come from [`prod-readiness-multisigs.json`](/Users/dev/dev/contracts2/script/mintburn/prod-readiness-multisigs.json), which is intended to be committed because the values are not secret. The file is a flat JSON object keyed by chain id.

Example shape:

```json
{
  "1": "0x...",
  "10": "0x...",
  "fallbackEOA": "0x..."
}
```

The chain multisig is used for ownership transfers and `DEFAULT_ADMIN_ROLE` handoff proposals. If a chain multisig is missing, the script falls back to `fallbackEOA` and prints a note next to the suggested command instead of adding a separate finding. Signer fixes are printed with a shell placeholder, for example `$CORRECT_SIGNER`, so the same value can be reused across commands if needed.

Checks performed:

- `SponsoredCCTPSrcPeriphery`: `owner`, `signer`
- `SponsoredOFTSrcPeriphery`: `owner`, `signer`
- `SponsoredCCTPDstPeriphery`: `FUNDS_SWEEPER_ROLE`, `PERMISSIONED_BOT_ROLE`, `signer`, `DEFAULT_ADMIN_ROLE`
- `DstOFTHandler`: `FUNDS_SWEEPER_ROLE`, `PERMISSIONED_BOT_ROLE`, `DEFAULT_ADMIN_ROLE`
- `DstOFTHandler`: `authorizedSrcPeripheryContracts` must match canonical latest `SponsoredOFTSrcPeriphery` deployments
- Destination multicall handler, queried live from the canonical dst contract: dev wallet must not hold `DEFAULT_ADMIN_ROLE` or `WHITELISTED_CALLER_ROLE`, and the dst contract must hold `WHITELISTED_CALLER_ROLE`
- Destination donation box, queried live from the canonical dst contract: `owner` must equal the dst contract

Default output prints only findings. `--full` also prints aligned `[OK]` verification rows for easy comparison.

For actionable `FAIL` and `WARN` findings, the script also prints ordered `cast send` proposals:

- `setSigner(...)` before `transferOwnership(...)` on src peripheries
- `grantRole(DEFAULT_ADMIN_ROLE, eventual owner)` before `revokeRole(DEFAULT_ADMIN_ROLE, dev)`
- `revokeRole(...)` proposals for `PERMISSIONED_BOT_ROLE`, `FUNDS_SWEEPER_ROLE`, and stale multicall whitelist access
- `setAuthorizedPeriphery(...)` proposals when OFT src mappings are stale
- `transferOwnership(...)` proposals when the donation box owner is wrong

If both the chain multisig and `fallbackEOA` are missing from the JSON file, the script prints a note instead of a `cast` command for that ownership/admin fix.

When stdout is a terminal, the suggested-command section uses bold/color formatting to make each contract block easier to scan. Set `NO_COLOR=1` to disable that.

For `hypercore-tokens.json`, the token metadata fields `name`, `index`, `tokenId`, `szDecimals`, `weiDecimals`, `isCanonical`, and `evmAddress` should track Hyperliquid's `spotMeta` API response. The fields `canBeUsedForAccountActivation`, `accountActivationFeeCore`, and `bridgeSafetyBufferCore` are maintained locally.
