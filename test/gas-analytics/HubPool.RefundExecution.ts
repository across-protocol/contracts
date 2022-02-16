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
  expect,
} from "../utils";
import * as consts from "../constants";
import { TokenRolesEnum } from "@uma/common";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { buildPoolRebalanceLeafTree, buildPoolRebalanceLeafs } from "../MerkleLib.utils";

require("dotenv").config();

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
const STARTING_LP_AMOUNT = SEND_AMOUNT; // This should be >= `SEND_AMOUNT` otherwise some relays will revert because
// the pool balance won't be sufficient to cover the relay.
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
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ hubPool, timer, weth, mockSpoke, mockAdapter } = await hubPoolFixture());

    // Seed data worker with bond tokens.
    await seedWallet(dataWorker, [], weth, consts.bondAmount.mul(10));
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    // Deploy test tokens for each chain ID
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
        await seedWallet(liquidityProvider, [_l1Token], undefined, STARTING_LP_AMOUNT);
        await enableTokensForLP(owner, hubPool, weth, [_l1Token]);
        await _l1Token.connect(liquidityProvider).approve(hubPool.address, STARTING_LP_AMOUNT);
        await hubPool.connect(liquidityProvider).addLiquidity(_l1Token.address, STARTING_LP_AMOUNT);
      }
    }
  });

  it(`Tree with 1 Leaf: ${REFUND_SEND_COUNT} total transfers, ${REFUND_TOKEN_COUNT} different tokens`, async function () {
    const { leafs, tree } = await constructSimpleTree();
    const leafIndexToExecute = 0;

    await hubPool.connect(dataWorker).initiateRelayerRefund(
      [3117], // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
      1, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
      tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
      consts.mockDestinationDistributionRoot, // destinationDistributionRoot. Not relevant for this test.
      consts.mockSlowRelayFulfillmentRoot // Mock root because this isn't relevant for this test.
    );

    // Advance time so the request can be executed and execute the request.
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    const txn = await hubPool
      .connect(dataWorker)
      .executeRelayerRefund(leafs[leafIndexToExecute], tree.getHexProof(leafs[leafIndexToExecute]));

    // Balances should have updated as expected for tokens contained in the first leaf.
    for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
      expect(await l1Tokens[leafIndexToExecute][i].balanceOf(hubPool.address)).to.equal(
        STARTING_LP_AMOUNT.sub(SEND_AMOUNT)
      );
      expect(await l1Tokens[leafIndexToExecute][i].balanceOf(mockAdapter.address)).to.equal(SEND_AMOUNT);
    }

    // Now that we've verified that the transaction succeeded, let's compute average gas costs.
    const receipt = await txn.wait();
    console.log(receipt.cumulativeGasUsed);
  });
});
