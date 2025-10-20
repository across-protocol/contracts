// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { DstOFTHandler } from "../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { AddressToBytes32 } from "../../contracts/libraries/AddressConverters.sol";

// forge script script/mintburn/SetAuthorizedPeriphery.s.sol:SetAuthorizedPeriphery --rpc-url hyper-evm -vvvv
contract SetAuthorizedPeriphery is Script {
    using AddressToBytes32 for address;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // --- START CONFIG ---
        uint32 srcEid = 30110; // Arbitrum
        address srcPeriphery = 0x2C4413C70Fd1BDB109d7DFEE7310f4B692Dec381;
        address dstHandlerAddress = 0x40ad479382Ad2a5c3061487A5094a677B00f6Cb0;
        // --- END CONFIG ---

        DstOFTHandler dstHandler = DstOFTHandler(payable(dstHandlerAddress));

        vm.startBroadcast(deployerPrivateKey);

        dstHandler.setAuthorizedPeriphery(srcEid, srcPeriphery.toBytes32());

        vm.stopBroadcast();
    }
}
