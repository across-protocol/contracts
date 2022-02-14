import {
  toBNWei,
  toBN,
  SignerWithAddress,
  seedWallet,
  Contract,
  ethers,
  getContractFactory,
  BigNumber,
  randomAddress,
} from "../utils";
import * as consts from "../constants";
import { TokenRolesEnum } from "@uma/common";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { buildPoolRebalanceLeafTree, buildPoolRebalanceLeafs } from "../MerkleLib.utils";

let hubPool: Contract, timer: Contract, weth: Contract, mockAdapter: Contract, mockSpoke: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
const l1Tokens: Contract[] = [];

const REFUND_TOKEN_COUNT = 10;
// const REFUND_CHAIN_COUNT = 10;
const REFUND_SEND_COUNT = 10; // Send amount per destination chain + token combo
const SEND_AMOUNT = toBNWei("10");
const LP_FEE = SEND_AMOUNT.div(toBN(10));

async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(TokenRolesEnum.MINTER, owner.address);
  return erc20;
}

// Construct the leafs that will go into the merkle tree.
async function constructSimpleTree() {
  const _destinationChainIds: number[] = [];
  const _l1Tokens: Contract[] = [];
  const _bundleLpFeeAmounts: BigNumber[][] = [];
  const _netSendAmounts: BigNumber[][] = [];

  for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
    _destinationChainIds.push(i);
    _l1Tokens.push(l1Tokens[i]);
    _bundleLpFeeAmounts[i] = [];
    _netSendAmounts[i] = [];
    for (let j = 0; j < REFUND_SEND_COUNT; j++) {
      _bundleLpFeeAmounts[i].push(LP_FEE);
      _netSendAmounts[i].push(SEND_AMOUNT);
    }

    // Set adapter for destination chain ID:
    await hubPool.setCrossChainContracts(_destinationChainIds[i], mockAdapter.address, mockSpoke.address);

    // Whitelist route
    console.log(_destinationChainIds[i], _l1Tokens[i].address);
    await hubPool.whitelistRoute(_destinationChainIds[i], _l1Tokens[i].address, randomAddress());
  }
  const leafs = buildPoolRebalanceLeafs(
    _destinationChainIds,
    _l1Tokens,
    _bundleLpFeeAmounts,
    _netSendAmounts, // netSendAmounts.
    _netSendAmounts // runningBalances.
  );
  const tree = await buildPoolRebalanceLeafTree(leafs);

  return { leafs, tree };
}

describe.only("Gas Analytics: HubPool Relayer Refund Execution", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ hubPool, timer, weth, mockSpoke, mockAdapter } = await hubPoolFixture());

    // Seed data worker with bond tokens.
    await seedWallet(dataWorker, [], weth, consts.bondAmount.mul(10));
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    // Deploy all test tokens
    for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
      l1Tokens.push(await deployErc20(owner, `Test Token #${i}`, `T-${i}`));
      await seedWallet(dataWorker, [l1Tokens[i]], undefined, consts.bondAmount);
      await seedWallet(liquidityProvider, [l1Tokens[i]], undefined, SEND_AMOUNT);
      await enableTokensForLP(owner, hubPool, weth, [l1Tokens[i]]);
      await l1Tokens[i].connect(liquidityProvider).approve(hubPool.address, SEND_AMOUNT);
      await l1Tokens[i].connect(dataWorker).approve(hubPool.address, consts.bondAmount);
      await hubPool.connect(liquidityProvider).addLiquidity(l1Tokens[i].address, SEND_AMOUNT);
    }
  });

  it(`Tree with 1 Leaf: ${REFUND_SEND_COUNT} total transfers, ${REFUND_TOKEN_COUNT} different tokens`, async function () {
    const { leafs, tree } = await constructSimpleTree();

    await hubPool.connect(dataWorker).initiateRelayerRefund(
      [3117], // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
      1, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
      tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
      consts.mockDestinationDistributionRoot, // destinationDistributionRoot. Not relevant for this test.
      consts.mockSlowRelayFulfillmentRoot // Mock root because this isn't relevant for this test.
    );

    // Advance time so the request can be executed and execute the request.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    console.log(leafs[0]);
    await hubPool.connect(dataWorker).executeRelayerRefund(leafs[0], tree.getHexProof(leafs[0]));

    // // Balances should have updated as expected.
    // expect(await weth.balanceOf(hubPool.address)).to.equal(consts.amountToLp.sub(wethToSendToL2));
    // expect(await weth.balanceOf(mockAdapter.address)).to.equal(wethToSendToL2);
    // expect(await dai.balanceOf(hubPool.address)).to.equal(consts.amountToLp.mul(10).sub(daiToSend));
    // expect(await dai.balanceOf(mockAdapter.address)).to.equal(daiToSend);

    // // Check the mockAdapter was called with the correct arguments for each method.
    // const relayMessageEvents = await mockAdapter.queryFilter(mockAdapter.filters.RelayMessageCalled());
    // expect(relayMessageEvents.length).to.equal(1); // Exactly one message send from L1->L2.
    // expect(relayMessageEvents[0].args?.target).to.equal(mockSpoke.address);
    // expect(relayMessageEvents[0].args?.message).to.equal(
    //   mockSpoke.interface.encodeFunctionData("initializeRelayerRefund", [
    //     consts.mockDestinationDistributionRoot,
    //     consts.mockSlowRelayFulfillmentRoot,
    //   ])
    // );

    // const relayTokensEvents = await mockAdapter.queryFilter(mockAdapter.filters.RelayTokensCalled());
    // expect(relayTokensEvents.length).to.equal(2); // Exactly two token transfers from L1->L2.
    // expect(relayTokensEvents[0].args?.l1Token).to.equal(weth.address);
    // expect(relayTokensEvents[0].args?.l2Token).to.equal(l2Weth);
    // expect(relayTokensEvents[0].args?.amount).to.equal(wethToSendToL2);
    // expect(relayTokensEvents[0].args?.to).to.equal(mockSpoke.address);
    // expect(relayTokensEvents[1].args?.l1Token).to.equal(dai.address);
    // expect(relayTokensEvents[1].args?.l2Token).to.equal(l2Dai);
    // expect(relayTokensEvents[1].args?.amount).to.equal(daiToSend);
    // expect(relayTokensEvents[1].args?.to).to.equal(mockSpoke.address);

    // // Check the leaf count was decremented correctly.
    // expect((await hubPool.refundRequest()).unclaimedPoolRebalanceLeafCount).to.equal(0);
  });
});
