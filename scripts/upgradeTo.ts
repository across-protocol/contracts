import { ethers, getContractFactory } from "../utils/utils";

async function main() {
  const [signer] = await ethers.getSigners();

  const spokePool = await getContractFactory("Arbitrum_SpokePool", { signer });
  const upgradeTo = spokePool.interface.encodeFunctionData("upgradeTo", ["0xB281f29CE1224147eadd3E469459A7A8188770AC"]);
  console.log(`upgradeTo bytes: `, upgradeTo);

  console.log(
    `Call relaySpokePoolAdminFunction() with the params [<chainId>, ${upgradeTo}] on this hub pool: https://goerli.etherscan.io/address/0x0e2817C49698cc0874204AeDf7c72Be2Bb7fCD5d#writeContract`
  );
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
