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
    [1_000_000, "0x0e2817C49698cc0874204AeDf7c72Be2Bb7fCD5d", L1_ADDRESS_MAP[chainId].weth],
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
