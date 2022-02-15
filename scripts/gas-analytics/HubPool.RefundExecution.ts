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
} from "../../test/utils";
import * as consts from "../../test/constants";
import { TokenRolesEnum } from "@uma/common";
import { hubPoolFixture, enableTokensForLP } from "../../test/HubPool.Fixture";
import { buildPoolRebalanceLeafTree, buildPoolRebalanceLeafs } from "../../test/MerkleLib.utils";

let hubPool: Contract, timer: Contract, weth: Contract, mockAdapter: Contract, mockSpoke: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

// Data structure to create pool rebalance leafs:
const l1Tokens: { [key: number]: Contract[] } = {};
const destinationChainIds: number[] = [];
const _bundleLpFeeAmounts: BigNumber[][] = [];
const _netSendAmounts: BigNumber[][] = [];

// Constants caller can tune to modify gas tests
const REFUND_TOKEN_COUNT = 10;
const REFUND_CHAIN_COUNT = 10;
const REFUND_SEND_COUNT = 10; // Send amount per destination chain + token combo
const SEND_AMOUNT = toBNWei("10");
const LP_FEE = SEND_AMOUNT.div(toBN(10));

async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(TokenRolesEnum.MINTER, owner.address);
  return erc20;
}

// Construct tree with REFUND_CHAIN_COUNT leaves, each containing REFUND_TOKEN_COUNT sends
async function constructSimpleTree() {
  for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
    _bundleLpFeeAmounts[i] = [];
    _netSendAmounts[i] = [];
    for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
      _bundleLpFeeAmounts[i].push(LP_FEE);
      _netSendAmounts[i].push(SEND_AMOUNT);

      // Whitelist route
      await hubPool.whitelistRoute(destinationChainIds[i], l1Tokens[i][j].address, randomAddress());
    }

    // Set adapter for destination chain ID:
    await hubPool.setCrossChainContracts(destinationChainIds[i], mockAdapter.address, mockSpoke.address);
  }
  const leafs = buildPoolRebalanceLeafs(
    destinationChainIds,
    Object.values(l1Tokens),
    _bundleLpFeeAmounts,
    _netSendAmounts, // netSendAmounts.
    _netSendAmounts // runningBalances.
  );
  const tree = await buildPoolRebalanceLeafTree(leafs);

  return { leafs, tree };
}

describe("Gas Analytics: HubPool Relayer Refund Execution", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ hubPool, timer, weth, mockSpoke, mockAdapter } = await hubPoolFixture());

    // Seed data worker with bond tokens.
    await seedWallet(dataWorker, [], weth, consts.bondAmount.mul(10));
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    // Deploy all test tokens for each chain ID
    for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
      destinationChainIds.push(i);
      l1Tokens[i] = [];
      for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
        const _l1Token = await deployErc20(owner, `Test Token #${i}`, `T-${i}`);
        l1Tokens[i].push(_l1Token);

        // Mint data worker amount of tokens needed to bond a new root
        await seedWallet(dataWorker, [_l1Token], undefined, consts.bondAmount);
        await _l1Token.connect(dataWorker).approve(hubPool.address, consts.bondAmount);

        // Mint LP amount of tokens needed to cover relay
        await seedWallet(liquidityProvider, [_l1Token], undefined, SEND_AMOUNT);
        await enableTokensForLP(owner, hubPool, weth, [_l1Token]);
        await _l1Token.connect(liquidityProvider).approve(hubPool.address, SEND_AMOUNT);
        await hubPool.connect(liquidityProvider).addLiquidity(_l1Token.address, SEND_AMOUNT);
      }
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
