// @notice Prints bytes input you'll need to send ETH from L2 aliased HubPool address to l2 recipient address via
// Arbitrum_RescueAdapter.

import { defaultAbiCoder, toWei } from "../test/utils";

async function main() {
  const amountOfEth = toWei("2.9");

  const message = defaultAbiCoder.encode(["uint256"], [amountOfEth]);
  console.log(`Message to include in call to relaySpokePoolAdminFunction: `, message);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
