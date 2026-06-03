// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";

// Deploys WithdrawImplementation via CREATE2. The impl's immutable `admin` is the
// AdminWithdrawManager — its CREATE2 address is predicted from (deployer, deployer, signer), which
// are all global, so the manager (and therefore this impl) lands at the same address on every chain.
//
// The withdraw impl is NOT part of clone identity (it is referenced in the policy merkle tree, not
// in cloneArgs), so its address uniformity is an operational convenience rather than a hard
// requirement for clone-address consistency. It is kept uniform anyway so the SDK and policy
// authors can reference one address everywhere.
//
// Deploy ordering: the AdminWithdrawManager does NOT need to exist yet — only its (deterministic)
// address is needed, which is predicted here. Deploy order between the two is therefore free.
//
// How to run:
// 1. Edit script/counterfactual/config.toml with the signer address
// 2. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 3. forge script script/counterfactual/DeployWithdrawImplementation.s.sol:DeployWithdrawImplementation --rpc-url $NODE_URL -vvvv
// 4. Verify simulation works
// 5. Deploy: append --broadcast --verify to the command above
contract DeployWithdrawImplementation is CounterfactualConfig {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address signer = _signer();
        address adminWithdrawManager = _predictAdminWithdrawManager(deployer, signer);

        console.log("Deploying WithdrawImplementation via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Immutable admin (predicted AdminWithdrawManager):", adminWithdrawManager);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(_deploySalt(), _withdrawImplInitCode(adminWithdrawManager));
        vm.stopBroadcast();

        console.log("WithdrawImplementation deployed to:", deployed);
    }
}
