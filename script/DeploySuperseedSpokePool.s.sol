// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";

import { Superseed_SpokePool } from "../contracts/Superseed_SpokePool.sol";
import { ITokenMessenger } from "../contracts/external/interfaces/CCTPInterfaces.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// forge script script/DeploySuperseedSpokePool.s.sol:DeploySuperseedSpokePool --rpc-url $RPC_URL --broadcast --verify -vvvv <ADDITIONAL_VERIFICATION_INFO>
contract DeploySuperseedSpokePool is Script, Test {
    address constant OP_WETH = 0x4200000000000000000000000000000000000006;
    address constant hubPool = 0xc186fA914353c44b2E33eBE05f21846F1048bEda;

    IERC20 SUPERSEED_USDC = IERC20(0x0459d257914d1c1b08D6Fb98Ac2fe17b02633EAD);
    uint32 constant quoteTimeBuffer = 3600;
    uint32 constant fillDeadlineBuffer = 3600 * 6;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        Superseed_SpokePool spokePool = new Superseed_SpokePool(
            OP_WETH,
            quoteTimeBuffer,
            fillDeadlineBuffer,
            SUPERSEED_USDC,
            ITokenMessenger(address(0))
        );
        address proxy = address(
            new ERC1967Proxy(address(spokePool), abi.encodeCall(Superseed_SpokePool.initialize, (0, hubPool, hubPool)))
        );
        spokePool = Superseed_SpokePool(payable(proxy));

        // Sanity Checks
        assertEq(hubPool, spokePool.crossDomainAdmin());
        assertEq(hubPool, spokePool.hubPool());
        assertEq(address(0), address(spokePool.cctpTokenMessenger()));
    }
}
