// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { DeploySolanaAdapter } from "../../../../../script/chain-adapters/DeploySolanaAdapter.s.sol";

contract DeploySolanaAdapterTest is Test {
    function testRejectSepoliaBeforeLoadingDeployerKey() public {
        DeploySolanaAdapter deployScript = new DeploySolanaAdapter();
        vm.chainId(11155111);
        vm.setEnv("MNEMONIC", "invalid mnemonic");
        vm.expectRevert(abi.encodeWithSelector(DeploySolanaAdapter.UnsupportedChain.selector, uint256(11155111)));
        deployScript.run();
    }
}
