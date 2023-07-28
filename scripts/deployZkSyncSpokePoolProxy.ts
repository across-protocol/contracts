import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import { Wallet } from "zksync-web3";
import { L1_ADDRESS_MAP } from "../deploy/consts";
require("dotenv").config();

import * as hre from "hardhat";

async function main() {
  const contractName = "Ethereum_SpokePool";
  console.log("Deploying " + contractName + "...");

  const chainId = await hre.getChainId();
  if (chainId !== "280") throw new Error("This script can only be run on zkSync testnet (chainId 280)");

  // mnemonic for local node rich wallet
  const testMnemonic = process.env.MNEMONIC ?? "";
  const zkWallet = Wallet.fromMnemonic(testMnemonic);

  const deployer = new Deployer(hre, zkWallet);

  const contract = await deployer.loadArtifact(contractName);
  const proxy = await hre.zkUpgrades.deployProxy(
    deployer.zkWallet,
    contract,
    [
      // Initial deposit ID
      1_000_000,
      // ZKErc20bridge
      "0x0e2817C49698cc0874204AeDf7c72Be2Bb7fCD5d",
      // ZKWETHBridge
      // TODO: Fill this in, this is set to the mainnet address for now
      "0x5aea5775959fbc2557cc8789bc1bf90a239d9a91",
      // Cross domain admin
      zkWallet.address,
      // HubPool
      // TODO: Fill this in, we need the HubPool address for the testnet
      zkWallet.address,
      L1_ADDRESS_MAP[chainId].weth,
    ],
    { initializer: "initialize" }
  );

  await proxy.deployed();
  console.log(contractName + " deployed to:", proxy.address);

  // proxy.connect(zkWallet);
  // const value = await box.retrieve();
  // console.log('Box value is: ', value.toNumber());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
