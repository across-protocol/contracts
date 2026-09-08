// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";

// Deploys the dispatcher (CounterfactualDeposit) bound to the chain-invariant beacon proxy. Since the proxy
// address is identical on every chain, so is the dispatcher's CREATE2 address.
//
// The dispatcher needs the beacon proxy address: zero-arg `run()` recomputes it like DeployCounterfactualBeacon
// (CREATE2 of the ERC1967Proxy over the bootstrap, owned by the deployer); `run(address beacon)` takes it
// explicitly. The beacon must already be deployed for the dispatcher to work (it reads BEACON.upgradeRoot()).
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDeposit.s.sol:DeployCounterfactualDeposit --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDeposit is CounterfactualConfig {
    /// @notice Zero-arg entry point: recomputes the beacon proxy address and deploys the dispatcher bound to it.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);
        this.run(_predictBeaconProxy(deployer));
    }

    /// @param beacon The CounterfactualBeacon proxy address (chain-invariant) to bind the dispatcher to.
    function run(address beacon) external {
        require(beacon != address(0), "Beacon cannot be zero address");
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        // Resolve the salt (which lazily loads config via file-reading cheatcodes) BEFORE startBroadcast;
        // constructing the StdConfig helper inside the broadcast region breaks forge's on-chain simulation.
        bytes32 salt = _deploySalt();

        console.log("Deploying CounterfactualDeposit via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Beacon:  ", beacon);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(salt, _dispatcherInitCode(beacon));
        vm.stopBroadcast();

        console.log("CounterfactualDeposit deployed to:", deployed);
    }
}
