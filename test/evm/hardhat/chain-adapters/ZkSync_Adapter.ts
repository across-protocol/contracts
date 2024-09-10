import { amountToLp, mockTreeRoot, refundProposalLiveness, bondAmount } from "./../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedWallet,
  randomAddress,
  toWei,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";

let hubPool: Contract, zkSyncAdapter: Contract, weth: Contract, dai: Contract, timer: Contract, mockSpoke: Contract;
let l2Weth: string, l2Dai: string, mainnetWeth: FakeContract;
let owner: SignerWithAddress,
  dataWorker: SignerWithAddress,
  liquidityProvider: SignerWithAddress,
  refundAddress: SignerWithAddress;
let zkSync: FakeContract, zkSyncErc20Bridge: FakeContract;

const zkSyncChainId = 324;

// TODO: Grab the following from relayer/CONTRACT_ADDRESSES dictionary?
const zkSyncAbi = [
  {
    inputs: [
      { internalType: "address", name: "_contractL2", type: "address" },
      { internalType: "uint256", name: "_l2Value", type: "uint256" },
      { internalType: "bytes", name: "_calldata", type: "bytes" },
      { internalType: "uint256", name: "_l2GasLimit", type: "uint256" },
      { internalType: "uint256", name: "_l2GasPerPubdataByteLimit", type: "uint256" },
      { internalType: "bytes[]", name: "_factoryDeps", type: "bytes[]" },
      { internalType: "address", name: "_refundRecipient", type: "address" },
    ],
    name: "requestL2Transaction",
    outputs: [{ internalType: "bytes32", name: "canonicalTxHash", type: "bytes32" }],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint256", name: "_gasPrice", type: "uint256" },
      { internalType: "uint256", name: "_l2GasLimit", type: "uint256" },
      { internalType: "uint256", name: "_l2GasPerPubdataByteLimit", type: "uint256" },
    ],
    name: "l2TransactionBaseCost",
    outputs: [{ internalType: "uint256", name: "", type: "uint256" }],
    stateMutability: "pure",
    type: "function",
  },
];

const zkSyncErc20BridgeAbi = [
  {
    inputs: [
      { internalType: "address", name: "_l2Receiver", type: "address" },
      { internalType: "address", name: "_l1Token", type: "address" },
      { internalType: "uint256", name: "_amount", type: "uint256" },
      { internalType: "uint256", name: "_l2TxGasLimit", type: "uint256" },
      { internalType: "uint256", name: "_l2TxGasPerPubdataByte", type: "uint256" },
      { internalType: "address", name: "_refundRecipient", type: "address" },
    ],
    name: "deposit",
    outputs: [{ internalType: "bytes32", name: "l2TxHash", type: "bytes32" }],
    stateMutability: "payable",
    type: "function",
  },
];

const l2TransactionBaseCost = toWei("0.0001");

describe("ZkSync Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider, refundAddress] = await ethers.getSigners();
    ({ weth, dai, l2Weth, l2Dai, hubPool, mockSpoke, timer } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai], weth, amountToLp);
    await seedWallet(liquidityProvider, [dai], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));

    zkSync = await smock.fake(zkSyncAbi, { address: "0x32400084C286CF3E17e7B677ea9583e60a000324" });
    zkSync = await smock.fake(zkSyncAbi, { address: "0x32400084C286CF3E17e7B677ea9583e60a000324" });
    zkSync.l2TransactionBaseCost.returns(l2TransactionBaseCost);
    zkSyncErc20Bridge = await smock.fake(zkSyncErc20BridgeAbi, {
      address: "0x57891966931Eb4Bb6FB81430E6cE0A03AAbDe063",
    });

    zkSyncAdapter = await (
      await getContractFactory("ZkSync_Adapter", owner)
    ).deploy(weth.address, refundAddress.address);

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("100000") });

    await hubPool.setCrossChainContracts(zkSyncChainId, zkSyncAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(zkSyncChainId, weth.address, l2Weth);
    await hubPool.setPoolRebalanceRoute(zkSyncChainId, dai.address, l2Dai);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(zkSyncChainId, functionCallData))
      .to.emit(zkSyncAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);
    expect(zkSync.requestL2Transaction).to.have.been.calledWith(
      mockSpoke.address,
      0,
      functionCallData,
      await zkSyncAdapter.L2_GAS_LIMIT(),
      await zkSyncAdapter.L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT(),
      [],
      refundAddress.address
    );
    expect(zkSync.requestL2Transaction).to.have.been.calledWithValue(l2TransactionBaseCost);
  });
  it("Correctly calls appropriate bridge functions when making ERC20 cross chain calls", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, zkSyncChainId);
    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // The correct functions should have been called on the optimism contracts.
    const expectedErc20L1ToL2BridgeParams = [
      mockSpoke.address,
      dai.address,
      tokensSendToL2,
      await zkSyncAdapter.L2_GAS_LIMIT(),
      await zkSyncAdapter.L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT(),
      refundAddress.address,
    ];
    expect(zkSyncErc20Bridge.deposit).to.have.been.calledWith(...expectedErc20L1ToL2BridgeParams);
    expect(zkSyncErc20Bridge.deposit).to.have.been.calledWithValue(l2TransactionBaseCost);
  });
  it("Correctly unwraps WETH and bridges ETH", async function () {
    const { leaves, tree } = await constructSingleChainTree(weth.address, 1, zkSyncChainId);

    await hubPool.connect(dataWorker).proposeRootBundle([3117], 1, tree.getHexRoot(), mockTreeRoot, mockTreeRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);

    // Since WETH is used as proposal bond, the bond plus the WETH are debited from the HubPool's balance.
    // The WETH used in the ZKSyncAdapter is withdrawn to ETH and then paid to the zksync mailbox.
    const proposalBond = await hubPool.bondAmount();
    await expect(() =>
      hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]))
    ).to.changeTokenBalance(weth, hubPool, leaves[0].netSendAmounts[0].add(proposalBond).mul(-1));
    expect(zkSync.requestL2Transaction).to.have.been.calledWith(
      mockSpoke.address,
      leaves[0].netSendAmounts[0].toString(),
      "0x",
      await zkSyncAdapter.L2_GAS_LIMIT(),
      await zkSyncAdapter.L1_GAS_TO_L2_GAS_PER_PUB_DATA_LIMIT(),
      [],
      refundAddress.address
    );
    expect(zkSync.requestL2Transaction).to.have.been.calledWithValue(
      l2TransactionBaseCost.add(leaves[0].netSendAmounts[0])
    );
  });
});
