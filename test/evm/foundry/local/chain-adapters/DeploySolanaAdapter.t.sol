// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { DeploySolanaAdapter } from "../../../../../script/chain-adapters/DeploySolanaAdapter.s.sol";

contract DeploySolanaAdapterTest is Test {
    function testRejectSepoliaBeforeLoadingDeployerKey() public {
        DeploySolanaAdapter deployScript = new DeploySolanaAdapter();
        vm.chainId(11155111);
        vm.setEnv("MNEMONIC", "invalid mnemonic");
        vm.expectRevert(
            "Solana_Adapter deployment is mainnet only: no compatible Solana devnet Spoke/Gateway is configured"
        );
        deployScript.run();
    }
}
