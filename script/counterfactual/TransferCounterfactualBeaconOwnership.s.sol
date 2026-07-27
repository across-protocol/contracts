// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualBeacon } from "../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";

// Initiates the Ownable2Step ownership transfer of the LIVE CounterfactualBeacon proxy to this chain's
// `ownerAndDirectWithdrawer` multisig from config.toml. Only works while the deployer (MNEMONIC index 0)
// is still the beacon owner. The transfer completes only when the multisig itself executes
// `acceptOwnership()` (0x79ba5097) on the proxy; until then the deployer remains owner and can re-point
// or cancel the pending transfer by calling `transferOwnership` again.
//
// Every terminal outcome prints a single machine-greppable line `Transfer status: <STATUS>`:
//   INITIATED         transferOwnership(multisig) sent (or would be, on a dry-run)
//   ALREADY-OWNER     the multisig already owns the beacon; nothing to do
//   ALREADY-PENDING   a transfer to the multisig is already awaiting acceptOwnership()
//   NOT-OWNER         beacon owner is neither the deployer nor the multisig — investigate before acting
//   NO-MULTISIG-CODE  ownerAndDirectWithdrawer holds no code on this chain (nothing could ever accept);
//                     deploy the multisig first — no tx attempted
//   NO-PROXY          no live beacon proxy on this chain — run DeployCounterfactualBeacon first
// Non-INITIATED outcomes return without reverting so a multi-chain shell loop can classify them.
//
// How to run (per chain):
//   source .env
//   forge script script/counterfactual/TransferCounterfactualBeaconOwnership.s.sol:TransferCounterfactualBeaconOwnership \
//     --rpc-url $NODE_URL_<chainId> -vvv
// Then append --broadcast to send the tx.
//
// Verify afterwards with CheckCounterfactualBeaconOwners.s.sol (reports owner/pendingOwner per chain).
contract TransferCounterfactualBeaconOwnership is CounterfactualConfig {
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);
        address multisig = _loadOperationalConfig().ownerAndDirectWithdrawer;

        console.log("============================================");
        console.log("CounterfactualBeacon ownership transfer");
        console.log("============================================");
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Multisig (ownerAndDirectWithdrawer):", multisig);

        // Live proxy: deployed-addresses.json first, CREATE2 prediction as fallback for chains deployed
        // since the last address extraction (the proxy address is chain-invariant by construction).
        address proxy = getDeployedAddress("CounterfactualBeacon", block.chainid, false);
        if (proxy == address(0)) proxy = _predictBeaconProxy(deployer);
        if (proxy.code.length == 0) {
            console.log("Transfer status: NO-PROXY (no live beacon proxy; run DeployCounterfactualBeacon first)");
            return;
        }
        console.log("Beacon proxy:", proxy);

        CounterfactualBeacon beacon = CounterfactualBeacon(proxy);
        address owner = beacon.owner();
        console.log("Current owner:", owner);
        if (owner == multisig) {
            console.log("Transfer status: ALREADY-OWNER");
            return;
        }
        if (owner != deployer) {
            console.log("Transfer status: NOT-OWNER (owner is neither the deployer nor the multisig)");
            return;
        }
        if (beacon.pendingOwner() == multisig) {
            console.log("Transfer status: ALREADY-PENDING (multisig must call acceptOwnership())");
            return;
        }

        // A pending transfer to a code-less address could never be accepted; refuse rather than leave a
        // dangling pending owner that looks like progress.
        if (multisig.code.length == 0) {
            console.log("Transfer status: NO-MULTISIG-CODE (deploy the multisig on this chain first)");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);
        beacon.transferOwnership(multisig);
        vm.stopBroadcast();

        console.log("Pending owner set to %s - complete with acceptOwnership() from the multisig", multisig);
        console.log("Transfer status: INITIATED");
    }
}
