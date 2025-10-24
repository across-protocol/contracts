// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "./utils/DeploymentUtils.sol";
import { SponsoredOFTSrcPeriphery } from "../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";

/// Example CLI usage:
/// forge script script/115DeploySrcOFTPeriphery.s.sol:DepoySrcOFTPeriphery \
///   --rpc-url <network> \
///   --sig "run(address,address,address,address)" \
///   0xToken 0xOftMessenger 0xSigner 0xFinalOwner
///
/// Final owner argument is optional – run with the four-arg overload to keep ownership
/// with the deployer. Passing the zero address renounces ownership after deploy.
contract DepoySrcOFTPeriphery is Script, Test, DeploymentUtils {
    enum OwnershipInstruction {
        KeepDeployer,
        Transfer,
        Renounce
    }

    struct OwnershipConfig {
        bool useDefaultOwner;
        address finalOwner;
    }

    function run() external pure {
        revert("Params not provided. See example usage in `script/115DeploySrcOFTPeriphery.s.sol`");
    }

    function run(address token, address oftMessenger, address signer) external {
        OwnershipConfig memory ownershipConfig = OwnershipConfig({ useDefaultOwner: true, finalOwner: address(0) });
        _deploy(token, oftMessenger, signer, ownershipConfig);
    }

    function run(address token, address oftMessenger, address signer, address finalOwner) external {
        OwnershipConfig memory ownershipConfig = OwnershipConfig({ useDefaultOwner: false, finalOwner: finalOwner });
        _deploy(token, oftMessenger, signer, ownershipConfig);
    }

    function _deploy(
        address token,
        address oftMessenger,
        address signer,
        OwnershipConfig memory ownershipConfig
    ) internal {
        console.log("Deploying SponsoredOFTSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        require(token != address(0), "Token address cannot be zero");
        require(oftMessenger != address(0), "OFT messenger cannot be zero");
        require(signer != address(0), "Signer cannot be zero");

        uint32 srcEid = uint32(getOftEid(block.chainid));

        (OwnershipInstruction ownershipInstruction, address resolvedFinalOwner) = _resolveOwnership(
            deployer,
            ownershipConfig
        );

        console.log("Token:", token);
        console.log("OFT messenger:", oftMessenger);
        console.log("Source EID:", uint256(srcEid));
        console.log("Signer:", signer);
        console.log("Deployer:", deployer);

        if (ownershipInstruction == OwnershipInstruction.Transfer) {
            console.log("Final owner (post-transfer):", resolvedFinalOwner);
        } else if (ownershipInstruction == OwnershipInstruction.Renounce) {
            console.log("Final owner (post-transfer): <renounce ownership>");
        } else {
            console.log("Final owner (post-transfer): deployer");
        }

        vm.startBroadcast(deployerPrivateKey);

        SponsoredOFTSrcPeriphery srcOftPeriphery = new SponsoredOFTSrcPeriphery(token, oftMessenger, srcEid, signer);

        console.log("SponsoredOFTSrcPeriphery deployed to:", address(srcOftPeriphery));

        if (ownershipInstruction == OwnershipInstruction.Transfer) {
            srcOftPeriphery.transferOwnership(resolvedFinalOwner);
            console.log("Ownership transferred to:", resolvedFinalOwner);
        } else if (ownershipInstruction == OwnershipInstruction.Renounce) {
            srcOftPeriphery.renounceOwnership();
            console.log("Ownership renounced to address(0)");
        } else {
            console.log("Ownership retained by deployer");
        }

        vm.stopBroadcast();
    }

    function _resolveOwnership(
        address deployer,
        OwnershipConfig memory config
    ) internal pure returns (OwnershipInstruction instruction, address finalOwner) {
        if (config.useDefaultOwner) {
            return (OwnershipInstruction.KeepDeployer, deployer);
        }

        if (config.finalOwner == address(0)) {
            return (OwnershipInstruction.Renounce, address(0));
        }

        if (config.finalOwner == deployer) {
            return (OwnershipInstruction.KeepDeployer, deployer);
        }

        return (OwnershipInstruction.Transfer, config.finalOwner);
    }
}
