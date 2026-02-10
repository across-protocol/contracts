// @notice Utility script to interact with HyperliquidDepositHandler contract.
// @dev Run with `yarn hardhat run ./scripts/hyperliquidDepositHandler.ts --network hyperevm`

import { getNodeUrl } from "../utils";
import { Contract, ethers } from "../utils/utils";
import { hre } from "../utils/utils.hre";

async function main() {
  const chainId = parseInt(await hre.getChainId());
  const nodeUrl = getNodeUrl(chainId);
  const wallet = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic);
  console.log(`Connected to node ${nodeUrl} for chain ${chainId}`);
  const signer = wallet.connect(new ethers.providers.JsonRpcProvider(nodeUrl));

  // Deposit USDH to spot:
  const amountToDeposit = ethers.utils.parseUnits("1", 6);
  const depositHandler = new Contract(
    "0x861E127036B28D32f3777B4676F6bbb9e007d195",
    [
      {
        inputs: [
          {
            internalType: "address",
            name: "token",
            type: "address",
          },
          {
            internalType: "uint256",
            name: "amount",
            type: "uint256",
          },
          {
            internalType: "address",
            name: "user",
            type: "address",
          },
        ],
        name: "depositToHypercore",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },

      {
        inputs: [
          { internalType: "address", name: "token", type: "address" },
          { internalType: "uint256", name: "evmAmount", type: "uint256" },
          { internalType: "address", name: "user", type: "address" },
        ],
        name: "sweepERC20ToUser",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [
          { internalType: "address", name: "token", type: "address" },
          { internalType: "uint256", name: "amount", type: "uint256" },
          { internalType: "address", name: "user", type: "address" },
        ],
        name: "sweepDonationBoxFundsToUser",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [
          { internalType: "address", name: "token", type: "address" },
          { internalType: "uint64", name: "coreAmount", type: "uint64" },
          { internalType: "address", name: "user", type: "address" },
        ],
        name: "sweepCoreFundsToUser",
        outputs: [],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [],
        name: "donationBox",
        outputs: [{ internalType: "contract DonationBox", name: "", type: "address" }],
        stateMutability: "view",
        type: "function",
      },
    ],
    signer
  );
  const usdh = new Contract(
    "0x111111a1a0667d36bD57c0A9f569b98057111111",
    [
      {
        inputs: [
          {
            internalType: "address",
            name: "guy",
            type: "address",
          },
          {
            internalType: "uint256",
            name: "wad",
            type: "uint256",
          },
        ],
        name: "approve",
        outputs: [
          {
            internalType: "bool",
            name: "",
            type: "bool",
          },
        ],
        stateMutability: "nonpayable",
        type: "function",
      },
      {
        inputs: [
          { internalType: "address", name: "to", type: "address" },
          { internalType: "uint256", name: "value", type: "uint256" },
        ],
        name: "transfer",
        outputs: [{ internalType: "bool", name: "", type: "bool" }],
        stateMutability: "nonpayable",
        type: "function",
      },
    ],
    signer
  );

  // Approve (1000 x amountToDeposit) USDH to be spent by the deposit handler.
  const approvalTxn = await usdh.approve(depositHandler.address, amountToDeposit.mul(1000));
  const receipt = await approvalTxn.wait();
  console.log(`approval:`, receipt);

  // Fund donation box with 1 activation fee + 1 wei.
  const donationBox = await depositHandler.donationBox();
  const transferTxn = await usdh.transfer(donationBox, amountToDeposit.add(1));
  const transferReceipt = await transferTxn.wait();
  console.log(`donationBox funding:`, transferReceipt);

  // // Sweep 1 USDH from the deposit handler on HyperEVM to a user's address.
  // const txn = await depositHandler.sweepERC20ToUser(
  //   usdh.address,
  //   "1000001",
  //   "0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D",
  // );
  // console.log(`sweepERC20ToUser`, await txn.wait());

  // // Sweep 1 USDH from the deposit handler on HyperCore to a user's address.
  // const txn = await depositHandler.sweepCoreFundsToUser(
  //   usdh.address,
  //   "100000001", // USDH has 8 decimals on Core.
  //   "0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D",
  // );
  // console.log(`sweepCoreFundsToUser`, await txn.wait());

  // // Sweep 1 USDH from the deposit handler's donation box on HyperEVM to a user's address.
  // const txn = await depositHandler.sweepDonationBoxFundsToUser(
  //   usdh.address,
  //   "1000000",
  //   "0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D",
  // );
  // console.log(`sweepDonationBoxFundsToUser`, await txn.wait());

  // Deposit 1 USDH from the user's address on HyperEVM to the user's account on HyperCore.
  // If user account needs to be activated, the deposit handler will pull 1 USDH + 1 wei from its donation box and
  // activate the user's account.
  const txn = await depositHandler.depositToHypercore(usdh.address, amountToDeposit, signer.address);
  console.log(`depositToHypercore`, await txn.wait());
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
