// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { DeploymentUtils } from "./../../utils/DeploymentUtils.sol";
import { SponsoredOFTSrcPeriphery } from "../../../contracts/periphery/mintburn/sponsored-oft/SponsoredOFTSrcPeriphery.sol";
import { IOAppCore } from "../../../contracts/interfaces/IOFT.sol";

/*
Example usage commands:

# Deploy using token key (loads ./script/mintburn/oft/<token>.toml)
forge script script/mintburn/oft/DeploySrcPeriphery.s.sol:DepoySrcOFTPeriphery \
  --sig "run(string,address)" usdt0 0xSigner \
  --rpc-url arbitrum --broadcast --verify -vvvv

# Deploy using token key with explicit final owner
forge script script/mintburn/oft/DeploySrcPeriphery.s.sol:DepoySrcOFTPeriphery \
  --sig "run(string,address,address)" usdt0 0xSigner 0xFinalOwner \
  --rpc-url arbitrum --broadcast --verify -vvvv

Note that both of these will update:
- the config + deployments file: ./script/mintburn/oft/<tokenName>.toml
- the `broadcast/` folder with the latest_run params (used by the precommit hooks to populate some generated artifacts file)

*/

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

    /// Deploy by token name key. Builds path: ./script/mintburn/oft/<tokenName>.toml
    /// Final owner assumed to be the deployer.
    function run(string memory tokenName, address signer) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        OwnershipConfig memory ownershipConfig = OwnershipConfig({ useDefaultOwner: true, finalOwner: address(0) });
        _deployFromConfig(configPath, signer, ownershipConfig);
    }

    /// Deploy by token name key with explicit final owner.
    function run(string memory tokenName, address signer, address finalOwner) external {
        require(bytes(tokenName).length != 0, "token key required");
        string memory configPath = string(abi.encodePacked("./script/mintburn/oft/", tokenName, ".toml"));
        OwnershipConfig memory ownershipConfig = OwnershipConfig({ useDefaultOwner: false, finalOwner: finalOwner });
        _deployFromConfig(configPath, signer, ownershipConfig);
    }

    function _deploy(
        address token,
        address oftMessenger,
        address signer,
        OwnershipConfig memory ownershipConfig
    ) internal returns (SponsoredOFTSrcPeriphery srcOftPeriphery) {
        console.log("Deploying SponsoredOFTSrcPeriphery...");
        console.log("Chain ID:", block.chainid);

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);

        require(token != address(0), "Token address cannot be zero");
        require(oftMessenger != address(0), "OFT messenger cannot be zero");
        require(signer != address(0), "Signer cannot be zero");

        uint32 srcEid = IOAppCore(oftMessenger).endpoint().eid();

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

        srcOftPeriphery = new SponsoredOFTSrcPeriphery(token, oftMessenger, srcEid, signer);

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
        return srcOftPeriphery;
    }

    function _deployFromConfig(
        string memory configPath,
        address signer,
        OwnershipConfig memory ownershipConfig
    ) internal {
        // Load config and enable write-back
        _loadConfig(configPath, true);

        address token = config.get("token").toAddress();
        address oftMessenger = config.get("oft_messenger").toAddress();

        require(token != address(0), "token not set");
        require(oftMessenger != address(0), "oft_messenger not set");
        require(signer != address(0), "signer not set");

        SponsoredOFTSrcPeriphery srcOftPeriphery = _deploy(token, oftMessenger, signer, ownershipConfig);

        // Persist the deployment address under this chain in TOML
        config.set("src_periphery", address(srcOftPeriphery));
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
