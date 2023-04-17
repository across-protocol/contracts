import { ethers, getContractFactory } from "../utils/utils";

async function main() {
  const [signer] = await ethers.getSigners();

  const spokePool = await getContractFactory("Ethereum_SpokePool", { signer });
  const upgradeTo = spokePool.interface.encodeFunctionData("upgradeTo", ["0x74f8b450606f025A4A40507158975b22f72DE96a"]);
  console.log(`upgradeTo bytes: `, upgradeTo);

  /// 7777 is special chain we use to test upgrades on goerli. This way we don't have to upgrade
  // the main spoke pool we use for deposits.
  console.log(
    `Call relaySpokePoolAdminFunction() with the params [7777, ${upgradeTo}] on this hub pool: https://goerli.etherscan.io/address/0x0e2817C49698cc0874204AeDf7c72Be2Bb7fCD5d#writeContract`
  );
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
