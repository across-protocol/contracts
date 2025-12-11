// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DonationBox } from "../../../contracts/chain-adapters/DonationBox.sol";
import { DeploymentUtils } from "../../utils/DeploymentUtils.sol";
import { DstOFTHandler } from "../../../contracts/periphery/mintburn/sponsored-oft/DstOFTHandler.sol";
import { DstHandlerConfigLib } from "./DstHandlerConfigLib.s.sol";
import { IOAppCore } from "../../../contracts/interfaces/IOFT.sol";
import { PermissionedMulticallHandler } from "../../../contracts/handlers/PermissionedMulticallHandler.sol";

/*
forge script script/mintburn/oft/DeployDstHandler.s.sol:DeployDstOFTHandler \
  --sig "run(string)" usdt0 \
  --rpc-url hyperevm -vvvv --broadcast --verify
 */
contract DeployDstOFTHandler is Script, Test, DeploymentUtils, DstHandlerConfigLib {
    function run(string memory tokenName) external {
        console.log("Deploying DstOFTHandler...");
        console.log("Chain ID:", block.chainid);

        _loadTokenConfig(tokenName);

        // Ensure we deploy on the configured destination fork so subsequent configuration
        // operates on the same fork where the contract exists.
        uint256 dstForkId = forkOf[block.chainid];
        vm.selectFork(dstForkId);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address ioft = config.get("oft_messenger").toAddress();
        address baseToken = config.get("token").toAddress();
        // address multicallHandler = _getOptionalAddress("multicall_handler");
        address oftEndpoint = address(IOAppCore(ioft).endpoint());
        require(oftEndpoint != address(0) && ioft != address(0) && baseToken != address(0), "config missing");

        vm.startBroadcast(deployerPrivateKey);

        DonationBox donationBox = new DonationBox();
        // if (multicallHandler == address(0)) {
        PermissionedMulticallHandler multicallHandler = new PermissionedMulticallHandler(deployer);
        // }
        DstOFTHandler dstOFTHandler = new DstOFTHandler(
            oftEndpoint,
            ioft,
            address(donationBox),
            baseToken,
            address(multicallHandler)
        );
        donationBox.transferOwnership(address(dstOFTHandler));
        // TODO: this won't work for multisig-owned `multicallHandler`s
        multicallHandler.grantRole(multicallHandler.WHITELISTED_CALLER_ROLE(), address(dstOFTHandler));

        console.log("DstOFTHandler deployed to:", address(dstOFTHandler));

        vm.stopBroadcast();

        // Persist the deployment address under this chain in TOML
        config.set("dst_handler", address(dstOFTHandler));

        // TODO: right, Foundry can't work with precompiles at all :(
        // _configureCoreTokenInfo(tokenName, address(dstOFTHandler));
        _configureAuthorizedPeripheries(address(dstOFTHandler), deployerPrivateKey);
    }

    /// @notice Returns a default zero address if not present
    function _getOptionalAddress(string memory key) internal returns (address addr) {
        try this.getAddress(key) returns (address value) {
            addr = value;
        } catch {
            console.log("Optional not found: ", key);
        }
    }

    function getAddress(string memory key) external returns (address) {
        return config.get(key).toAddress();
    }
}
