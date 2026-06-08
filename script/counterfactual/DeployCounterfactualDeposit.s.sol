// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualBeaconBootstrap } from "../../contracts/periphery/counterfactual/CounterfactualBeaconBootstrap.sol";
import { ICounterfactualBeacon } from "../../contracts/interfaces/ICounterfactualBeacon.sol";
import { CounterfactualDeposit } from "../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";

// Deploys the dispatcher (CounterfactualDeposit) bound to the chain-invariant beacon proxy. Because the
// beacon proxy address is identical on every chain, the dispatcher init code (and thus its CREATE2 address)
// is identical on every chain.
//
// NOTE: the dispatcher needs the beacon proxy address. The zero-arg `run()` recomputes it the same way
// DeployCounterfactualBeacon does (CREATE2 of the ERC1967Proxy over the bootstrap, owned by the deployer);
// `run(address beacon)` lets a caller pass it explicitly. The beacon must already be deployed for the
// dispatcher to be usable (CounterfactualDeposit reads BEACON.upgradeRoot()).
//
// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDeposit.s.sol:DeployCounterfactualDeposit --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDeposit is CounterfactualConfig {
    /// @notice Zero-arg entry point: recomputes the chain-invariant beacon proxy address and deploys the
    ///         dispatcher bound to it.
    function run() external {
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
        address deployer = vm.addr(deployerPrivateKey);
        this.run(_predictBeaconProxy(deployer));
    }

    /// @param beacon The CounterfactualBeacon proxy address (chain-invariant) to bind the dispatcher to.
    function run(address beacon) external {
        require(beacon != address(0), "Beacon cannot be zero address");
        uint256 deployerPrivateKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDeposit).creationCode,
            abi.encode(ICounterfactualBeacon(beacon))
        );

        console.log("Deploying CounterfactualDeposit via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("Beacon:  ", beacon);

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDeposit deployed to:", deployed);
    }

    /// @notice Predicts the chain-invariant beacon proxy address for the given deployer (bootstrap owner).
    function _predictBeaconProxy(address deployer) internal pure returns (address) {
        address bootstrap = _predictCreate2(bytes32(0), type(CounterfactualBeaconBootstrap).creationCode);
        bytes memory proxyInitCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(bootstrap, abi.encodeCall(CounterfactualBeaconBootstrap.initialize, (deployer)))
        );
        return _predictCreate2(bytes32(0), proxyInitCode);
    }
}
