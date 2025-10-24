// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Config } from "forge-std/Config.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "./../../utils/DeploymentUtils.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";

/*
Example usage commands:

# Config-driven deploy (recommended) – pass signer as CLI arg
forge script script/mintburn/oft/115DeploySrcOFTPeriphery.s.sol:DepoySrcOFTPeriphery \
  --sig "run(address)" 0xSigner \
  --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv

# Config-driven with custom config path
forge script script/mintburn/oft/115DeploySrcOFTPeriphery.s.sol:DepoySrcOFTPeriphery \
  --sig "run(string,address)" ./script/mintburn/oft/deployments.toml 0xSigner \
  --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv

# Manual param mode (legacy)
forge script script/mintburn/oft/115DeploySrcOFTPeriphery.s.sol:DepoySrcOFTPeriphery \
  --sig "run(address,address,address)" 0xToken 0xOFTMessenger 0xSigner \
  --rpc-url $ARBITRUM_RPC_URL --broadcast -vvvv
*/
/// Final owner argument is optional – run with the three-arg overload to keep ownership
/// with the deployer. Passing the zero address renounces ownership after deploy.
contract DepoySrcOFTPeriphery is Script, Config, Test, DeploymentUtils {
    string internal constant DEFAULT_CONFIG_PATH = "./script/mintburn/oft/deployments.toml";
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
        revert("Missing signer. Use run(address) or run(string,address)");
    }

    function run(address signer) external {
        _deployFromConfig(DEFAULT_CONFIG_PATH, signer);
    }

    function run(string memory configPath, address signer) external {
        _deployFromConfig(bytes(configPath).length == 0 ? DEFAULT_CONFIG_PATH : configPath, signer);
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

    function _deployFromConfig(string memory configPath, address signer) internal {
        // Load config and enable write-back
        _loadConfig(configPath, true);

        console.log("Deploying SponsoredOFTSrcPeriphery (config-driven)...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        address token = config.get("token").toAddress();
        address oftMessenger = config.get("oft_messenger").toAddress();

        require(token != address(0), "token not set");
        require(oftMessenger != address(0), "oft_messenger not set");
        require(signer != address(0), "signer not set");

        uint32 srcEid = uint32(getOftEid(block.chainid));

        console.log("Token:", token);
        console.log("OFT messenger:", oftMessenger);
        console.log("Source EID:", uint256(srcEid));
        console.log("Signer:", signer);
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);
        SponsoredOFTSrcPeriphery srcOftPeriphery = new SponsoredOFTSrcPeriphery(token, oftMessenger, srcEid, signer);
        vm.stopBroadcast();

        console.log("SponsoredOFTSrcPeriphery deployed to:", address(srcOftPeriphery));

        // Persist the deployment address under this chain in TOML
        config.set("src_periphery", address(srcOftPeriphery));
        config.set("src_periphery_deploy_block", block.number);
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
