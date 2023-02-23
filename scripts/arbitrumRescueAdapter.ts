// @notice Prints bytes input you'll need to send ETH from L2 aliased HubPool address to l2 recipient address via
// Arbitrum_RescueAdapter.

import { defaultAbiCoder, toWei } from "../test/utils";

async function main() {
  const amountOfEth = toWei("2.9");

  const message = defaultAbiCoder.encode(
    ["address", "uint256"],
    ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "365901230909"]
  );
  console.log(`Message to include in call to relaySpokePoolAdminFunction: `, message);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
