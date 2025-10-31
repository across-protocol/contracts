### Deployment process. It's IMPORTANT to perform all steps, otherwise funds WILL get lost

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

3. **Activate $DEPLOYED_DST_OFT account on HyperCore**

Go to Hyperliquid UI and set 1 USDC to it. Check activation status with: (TODO: paste command; hyperliquid RPC call)

4. Transfer ownership to multisig / trusted account / renounce ownership of DstOftHandler. TODO: could be enabled in the script if we could set core token info from there ... Foundry doesn't let us interact with precompiles from scripts (can't skip sim)

### Verifying the contracts

This is a bit tricky. After deployment, 2/4 will fail verification: DstOFTHandler + HyperCoreFlowExecutor.

- find deployed addrs in broadcast/DeployDstHandler.s.sol/<deployment-chain>/latest-run.json
- call a foundry fn, example for HyperCoreFlowExecutor:

```
forge verify-contract 0x2beF20D17a17f6903017d27D1A35CC9Dc72b0888 contracts/periphery/mintburn/HyperCoreFlowExecutor.sol:HyperCoreFlowExecutor --show-standard-json-input > stdJson.json
```

This will produce a standard json file usable for manual verification on the scan.
But you'll need to edit it.
In particular, the `IAccessControl.sol` is bundled incorrectly.
You need to change

```
    "node_modules/@openzeppelin/contracts/access/IAccessControl.sol": {
      "content": "// SPDX-License-Identifier: MIT\n// OpenZeppelin Contracts v4.4.1 ..."
    },
```

to

```
    "node_modules/@openzeppelin/contracts-v5/access/IAccessControl.sol": {
      "content": "// SPDX-License-Identifier: MIT\n// OpenZeppelin Contracts (last updated v5.4.0) (access/IAccessControl.sol)\n\npragma solidity >=0.8.4;\n\n/**\n * @dev External interface of AccessControl declared to support ERC-165 detection.\n */\ninterface IAccessControl {\n    /**\n     * @dev The `account` is missing a role.\n     */\n    error AccessControlUnauthorizedAccount(address account, bytes32 neededRole);\n\n    /**\n     * @dev The caller of a function is not the expected one.\n     *\n     * NOTE: Don't confuse with {AccessControlUnauthorizedAccount}.\n     */\n    error AccessControlBadConfirmation();\n\n    /**\n     * @dev Emitted when `newAdminRole` is set as ``role``'s admin role, replacing `previousAdminRole`\n     *\n     * `DEFAULT_ADMIN_ROLE` is the starting admin for all roles, despite\n     * {RoleAdminChanged} not being emitted to signal this.\n     */\n    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);\n\n    /**\n     * @dev Emitted when `account` is granted `role`.\n     *\n     * `sender` is the account that originated the contract call. This account bears the admin role (for the granted role).\n     * Expected in cases where the role was granted using the internal {AccessControl-_grantRole}.\n     */\n    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);\n\n    /**\n     * @dev Emitted when `account` is revoked `role`.\n     *\n     * `sender` is the account that originated the contract call:\n     *   - if using `revokeRole`, it is the admin role bearer\n     *   - if using `renounceRole`, it is the role bearer (i.e. `account`)\n     */\n    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);\n\n    /**\n     * @dev Returns `true` if `account` has been granted `role`.\n     */\n    function hasRole(bytes32 role, address account) external view returns (bool);\n\n    /**\n     * @dev Returns the admin role that controls `role`. See {grantRole} and\n     * {revokeRole}.\n     *\n     * To change a role's admin, use {AccessControl-_setRoleAdmin}.\n     */\n    function getRoleAdmin(bytes32 role) external view returns (bytes32);\n\n    /**\n     * @dev Grants `role` to `account`.\n     *\n     * If `account` had not been already granted `role`, emits a {RoleGranted}\n     * event.\n     *\n     * Requirements:\n     *\n     * - the caller must have ``role``'s admin role.\n     */\n    function grantRole(bytes32 role, address account) external;\n\n    /**\n     * @dev Revokes `role` from `account`.\n     *\n     * If `account` had been granted `role`, emits a {RoleRevoked} event.\n     *\n     * Requirements:\n     *\n     * - the caller must have ``role``'s admin role.\n     */\n    function revokeRole(bytes32 role, address account) external;\n\n    /**\n     * @dev Revokes `role` from the calling account.\n     *\n     * Roles are often managed via {grantRole} and {revokeRole}: this function's\n     * purpose is to provide a mechanism for accounts to lose their privileges\n     * if they are compromised (such as when a trusted device is misplaced).\n     *\n     * If the calling account had been granted `role`, emits a {RoleRevoked}\n     * event.\n     *\n     * Requirements:\n     *\n     * - the caller must be `callerConfirmation`.\n     */\n    function renounceRole(bytes32 role, address callerConfirmation) external;\n}\n"
    },
```

in that file.
The full latter thing(if it ever changes) can be found in `out/` folder for the contract that you were building (you'll need to remove some fields)

### Adding finalToken

TODO. Roughly:

- configure coreTokenInfo + finalTokenInfo
- before configuring finalTokenInfo, predictSwapHandler -> activate that on HyperCore
