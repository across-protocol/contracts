// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

// How to run:
// 1. Compile Tron artifacts: FOUNDRY_PROFILE=tron forge build
// 2. source .env (needs MNEMONIC, NODE_URL_728126428 or NODE_URL_3448148188)
// 3. forge script script/counterfactual/tron/TronDeployCounterfactualDepositSpokePool.s.sol \
//      --sig "run(uint256,address,address,address)" <chainId> <spokePool> <signer> <wrappedNativeToken>

contract TronDeployCounterfactualDepositSpokePool is Script {
    function run(uint256 chainId, address spokePool, address signer, address wrappedNativeToken) external {
        string memory artifactPath = string.concat(
            vm.projectRoot(),
            "/out-tron/CounterfactualDepositSpokePool.sol/CounterfactualDepositSpokePool.json"
        );
        string memory deployScript = string.concat(vm.projectRoot(), "/script/counterfactual/tron/deploy.ts");
        bytes memory encodedArgs = abi.encode(spokePool, signer, wrappedNativeToken);

        string[] memory cmd = new string[](6);
        cmd[0] = "npx";
        cmd[1] = "ts-node";
        cmd[2] = deployScript;
        cmd[3] = vm.toString(chainId);
        cmd[4] = artifactPath;
        cmd[5] = vm.toString(encodedArgs);

        bytes memory result = vm.ffi(cmd);
        address deployed = abi.decode(result, (address));
        console.log("Deployed CounterfactualDepositSpokePool:", deployed);
    }
}
