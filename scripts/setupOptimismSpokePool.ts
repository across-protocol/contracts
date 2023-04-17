// @notice Logs ABI-encoded function data that can be relayed from HubPool to OptimismSpokePool to set it up.

import { getContractFactory, ethers, hre } from "../utils/utils";
import * as consts from "../test/constants";

async function main() {
  const [signer] = await ethers.getSigners();

  // We need to set the token bridge for custom L2 tokens like DAI:
  const spokePool = await getContractFactory("Optimism_SpokePool", { signer });
  const setTokenBridgeDai = spokePool.interface.encodeFunctionData("setTokenBridge", [
    "0xda10009cbd5d07dd0cecc66161fc93d7c9000da1", // L2 DAI
    "0x467194771dAe2967Aef3ECbEDD3Bf9a310C76C65", // L2 DAI Custom Bridge
  ]);
  console.log(`(DAI) setTokenBridge: `, setTokenBridgeDai);

  // WETH is also not verified on the optimism explorer so we should approve it to be spent by the spoke pool.
  const ERC20 = await getContractFactory("ExpandedERC20", { signer });
  const weth = await ERC20.attach("0x4200000000000000000000000000000000000006");
  const deployedSpokePool = await hre.deployments.get("Optimism_SpokePool");
  const approval = await weth.approve(deployedSpokePool.address, consts.maxUint256);
  console.log(`Approved WETH to be spent by SpokePool @ ${deployedSpokePool.address}: `, approval.hash);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
