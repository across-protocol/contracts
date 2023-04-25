import "hardhat-deploy";
import hre from "hardhat";
import { L2_ADDRESS_MAP } from "./consts";
import { getContractFactory } from "../utils";

const func = async function () {
  const { upgrades, run, getChainId, getNamedAccounts } = hre;

  const chainId = parseInt(await getChainId());
  const hubPool = await hre.companionNetworks.l1.deployments.get("HubPool");
  const { deployer } = await getNamedAccounts();

  // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
  // with deprecated spoke pool.
  // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
  const constructorArgs = [
    1_000_000,
    // The same token bridger must be deployed on mainnet and polygon, so its easier
    // to reuse it.
    "0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57",
    hubPool.address,
    hubPool.address,
    L2_ADDRESS_MAP[chainId].wMatic,
    L2_ADDRESS_MAP[chainId].fxChild,
  ];
  const spokePool = await upgrades.deployProxy(
    await getContractFactory("Polygon_SpokePool", deployer),
    constructorArgs,
    {
      kind: "uups",
    }
  );
  const instance = await spokePool.deployed();
  console.log(`SpokePool deployed @ ${instance.address}`);
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(instance.address);
  console.log(`Implementation deployed @ ${implementationAddress}`);

  // hardhat-upgrades overrides the `verify` task that ships with `hardhat` so that if the address passed
  // is a proxy, hardhat will first verify the implementation and then the proxy and also link the proxy
  // to the implementation's ABI on etherscan.
  // https://docs.openzeppelin.com/upgrades-plugins/1.x/api-hardhat-upgrades#verify
  await run("verify:verify", {
    address: instance.address,
  });
};

module.exports = func;
func.tags = ["PolygonSpokePool", "polygon"];
