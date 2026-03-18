// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { console } from "forge-std/console.sol";
import { DeploymentUtils } from "../utils/DeploymentUtils.sol";
import { CounterfactualDepositOFT } from "../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x" and ETHERSCAN_API_KEY="x"
// 2. forge script script/counterfactual/DeployCounterfactualDepositOFT.s.sol:DeployCounterfactualDepositOFT \
//      --sig "run(address,uint32)" <oftSrcPeriphery> <srcEid> \
//      --rpc-url $NODE_URL -vvvv
// 3. Verify simulation works
// 4. Deploy: append --broadcast --verify to the command above
contract DeployCounterfactualDepositOFT is DeploymentUtils {
    function run(address oftSrcPeriphery, uint32 srcEid) external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, uint32(vm.envOr("DEPLOYER_INDEX", uint256(0))));

        require(oftSrcPeriphery != address(0), "OFT SrcPeriphery cannot be zero address");

        bytes memory initCode = abi.encodePacked(
            type(CounterfactualDepositOFT).creationCode,
            abi.encode(oftSrcPeriphery, srcEid)
        );
        console.log("Deploying CounterfactualDepositOFT via CREATE2...");
        console.log("Chain ID:", block.chainid);
        console.log("OFT SrcPeriphery:", oftSrcPeriphery);
        console.log("Source EID:", uint256(srcEid));

        vm.startBroadcast(deployerPrivateKey);
        address deployed = _deployCreate2(bytes32(0), initCode);
        vm.stopBroadcast();

        console.log("CounterfactualDepositOFT deployed to:", deployed);
    }
}
