// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { CounterfactualConfig } from "./CounterfactualConfig.sol";
import { CounterfactualDepositCCTP } from "../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";

// How to run (zero-arg, reads from constants + deployed addresses):
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositCCTP.s.sol:DeployCounterfactualDepositCCTP \
//      --rpc-url $NODE_URL -vvvv
// 3. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositCCTP is CounterfactualConfig {
    /// @notice Zero-arg entry point: resolves all params from constants and deployed addresses.
    function run() external {
        require(hasCctpDomain(block.chainid), "Chain does not support CCTP");
        address srcPeriphery = _resolveCctpPeriphery();
        require(srcPeriphery != address(0), "CCTP periphery not deployed on this chain");
        this.run(srcPeriphery, getCircleDomainId(block.chainid));
    }

    function run(address srcPeriphery, uint32 sourceDomain) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        require(srcPeriphery != address(0), "SrcPeriphery cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositCCTP).creationCode,
            abi.encode(srcPeriphery, sourceDomain)
        );
        console.log("Deploying CounterfactualDepositCCTP via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("SrcPeriphery:", srcPeriphery);
        console.log("Source domain:", uint256(sourceDomain));

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositCCTP deployed to:", deployed);
    }
}
