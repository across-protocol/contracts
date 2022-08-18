// zksync block explorer does not have contract verification yet so calling contracts via GUI is impossible. This file
// contains useful scripts to interact with zksync goerli contracts. To run, run:
// yarn hardhat run ./scripts/zksync.ts --network zksync-goerli

import { getContractFactory, ethers, toBN, findArtifactFromPath } from "../test/utils";
import { Contract, ContractFactory } from "ethers";
import { assert } from "console";

export const weth9Abi = [
  {
    constant: false,
    inputs: [{ name: "wad", type: "uint256" }],
    name: "withdraw",
    outputs: [],
    payable: false,
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    constant: false,
    inputs: [],
    name: "deposit",
    outputs: [],
    payable: true,
    stateMutability: "payable",
    type: "function",
  },
  {
    constant: true,
    inputs: [{ name: "", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
    payable: false,
    stateMutability: "view",
    type: "function",
  },
];

async function main() {
  const [signer] = await ethers.getSigners();

  const config = {
    spokePoolAddress: "0x63b25F1CdD7d9873A8D59717762396d4e6A46b83",
    wethAddress: "0xd3765838f9600ccff3d01efa83496599e0984bd2",
    l2Erc20AddressToTest: "0xd3765838f9600ccff3d01efa83496599e0984bd2", // WETH
    // l2Erc20AddressToTest: "0xE9f4149276E8a4F8DB89E0E3bb78fD853F01e87D", // DAI
    // l2Erc20AddressToTest: "0x5c221e77624690fff6dd741493d735a17716c26b", // USDC
    depositDestinationChainId: 5,
    rootBundleIdToExecute: 1,
    amountToDepositIntoSpokePool: toBN("200000000000000000"),
  };
  console.log(`Script config: `, config);

  // Initialize contracts:
  const SpokePoolArtifact = findArtifactFromPath("ZkSync_SpokePool", `${__dirname}/../artifacts-zk/contracts`);
  const SpokePool = new ContractFactory(SpokePoolArtifact.abi, SpokePoolArtifact.bytecode, signer);
  const spokePool = await SpokePool.attach(config.spokePoolAddress);
  const ERC20 = await getContractFactory("ERC20", { signer });
  const erc20 = await ERC20.attach(config.l2Erc20AddressToTest);
  const WETH = new Contract(config.wethAddress, weth9Abi, signer);
  const weth = await WETH.attach(config.wethAddress);

  // Log EnabledDepositRoute on SpokePool to test that L1 message arrived to L2:
  const filter = spokePool.filters.EnabledDepositRoute();
  const events = await spokePool.queryFilter(filter, 1019607, 1019607);
  events.forEach((e) => {
    console.log(`Found EnabledDepositRouteEvent in ${e.transactionHash}: `, e.args);
  });

  // Log state from SpokePool
  const originChainId = await spokePool.chainId();
  console.log(`SpokePool chainId(): ${originChainId.toString()}`);
  const currentTime = await spokePool.getCurrentTime();
  console.log(`SpokePool getCurrentTime(): ${currentTime.toString()}`);
  const wethAddress = await spokePool.wrappedNativeToken();
  assert(wethAddress === weth.address, "SpokePool.wrappedNativeToken !== wethAddress");
  const hubPool = await spokePool.hubPool();
  console.log(`SpokePool hubPool(): ${hubPool}`);
  const enabled = await spokePool.enabledDepositRoutes(erc20.address, config.depositDestinationChainId);
  console.log(`Deposit route to ${config.depositDestinationChainId} enabled? ${enabled}`);
  const rootBundles = await spokePool.rootBundles(config.rootBundleIdToExecute);
  console.log(`SpokePool rootBundles(${config.rootBundleIdToExecute}):`, rootBundles);

  // Set allowance if depositing funds
  const allowance = await erc20.allowance(signer.address, spokePool.address);
  if (
    config.amountToDepositIntoSpokePool.gt(0) &&
    allowance.lt(config.amountToDepositIntoSpokePool) &&
    erc20.address !== wethAddress
  ) {
    const txn = await erc20.approve(spokePool.address, config.amountToDepositIntoSpokePool);
    console.log(
      `Approving SpokePool to spend ${config.amountToDepositIntoSpokePool} of ${config.l2Erc20AddressToTest}`,
      await txn.wait()
    );
  }
  const balance = await erc20.balanceOf(signer.address);
  const spokeBalance = await erc20.balanceOf(spokePool.address);
  console.log(`${signer.address} ERC20 balance for ${config.l2Erc20AddressToTest}: ${balance.toString()}`);
  console.log(`${spokePool.address} ERC20 balance for ${config.l2Erc20AddressToTest}: ${spokeBalance.toString()}`);

  // Write transactions:

  // Wrap ETH:
  // const wrap = await weth.deposit({
  //   value: config.amountToDepositIntoSpokePool.toString(),
  //   gasPrice: "100000000",
  //   gasLimit: "100000",
  // });
  // console.log(`Wrapped ETH:`, await wrap.wait())

  // Deposit WETH into spoke pool so we can execute a relayer refund leaf
  // const deposit = await spokePool
  //   .deposit(
  //       signer.address,
  //       erc20.address,
  //       config.amountToDepositIntoSpokePool.toString(),
  //       config.depositDestinationChainId,
  //       "1000000000000000", // relayer fee pct
  //       currentTime.toString(),
  //       {
  //         value: (erc20.address === weth.address ? config.amountToDepositIntoSpokePool.toString() : "0"),
  //         // Note: When calling contract methods using zksync-web3 with a `value`, a type error occurs because
  //         // estimateGas() does not forward msg.value to Contracts functions. Temporary solution when calling
  //         // payable functions in contracts is adding additional params gasPrice and gasLimit so that estimateGas()
  //         // is not called before creating transaction.
  //         gasPrice: "100000000",
  //         gasLimit: "100000"
  //       }
  //   )
  //   const depositReceipt = await deposit.wait()
  //   console.log(`Deposited ${erc20.address} into SpokePool:`, depositReceipt)

  // const execute = await spokePool.executeRelayerRefundLeaf(
  //   config.rootBundleIdToExecute,
  //   {
  //     // Recreating leaf constructed in  './buildSampleTree.ts'
  //     amountToReturn: toBN("100000000000000000"), // 0.1
  //     chainId: originChainId,
  //     refundAmounts: [toBN("100000000000000000")], // -0.1
  //     leafId: 0,
  //     l2TokenAddress: erc20.address,
  //     refundAddresses: ["0x9a8f92a830a5cb89a3816e3d267cb7791c16b04d"],
  //   },
  //   []
  // );
  // const executeReceipt = await execute.wait();
  // console.log(`Executed RelayerRefundLeaf: `, executeReceipt);
}

main().then(
  () => process.exit(0),
  (error) => {
    console.log(error);
    process.exit(1);
  }
);
