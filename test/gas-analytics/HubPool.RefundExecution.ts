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
import { buildPoolRebalanceLeafTree, buildPoolRebalanceLeafs, PoolRebalanceLeaf } from "../MerkleLib.utils";
import { MerkleTree } from "../../utils/MerkleTree";

require("dotenv").config();

let hubPool: Contract, timer: Contract, weth: Contract, mockAdapter: Contract, mockSpoke: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

// Associates an array of L1 tokens to sends refunds for to each chain ID.
interface L1_TOKENS_MAPPING {
  [key: number]: Contract[];
}
let l1Tokens: L1_TOKENS_MAPPING;
let destinationChainIds: number[];
let leaves: PoolRebalanceLeaf[];
let tree: MerkleTree<PoolRebalanceLeaf>;

// Constants caller can tune to modify gas tests
const REFUND_TOKEN_COUNT = 10;
const REFUND_CHAIN_COUNT = 10;
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
async function constructSimpleTree(_destinationChainIds: number[], _l1Tokens: L1_TOKENS_MAPPING) {
  const _bundleLpFeeAmounts: BigNumber[][] = [];
  const _netSendAmounts: BigNumber[][] = [];
  for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
    _bundleLpFeeAmounts[i] = [];
    _netSendAmounts[i] = [];
    // Set adapter for destination chain ID:
    await hubPool.setCrossChainContracts(_destinationChainIds[i], mockAdapter.address, mockSpoke.address);
    for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
      _bundleLpFeeAmounts[i].push(LP_FEE);
      _netSendAmounts[i].push(SEND_AMOUNT);

      // Whitelist route
      await hubPool.whitelistRoute(_destinationChainIds[i], _l1Tokens[i][j].address, randomAddress());
    }
  }
  const leaves = buildPoolRebalanceLeafs(
    _destinationChainIds,
    Object.values(_l1Tokens),
    _bundleLpFeeAmounts,
    _netSendAmounts, // netSendAmounts.
    _netSendAmounts // runningBalances.
  );
  const tree = await buildPoolRebalanceLeafTree(leaves);

  return { leaves, tree };
}

describe("Gas Analytics: HubPool Relayer Refund Execution", function () {
  before(async function () {
    if (!process.env.GAS_TEST_ENABLED) this.skip();
  });

  beforeEach(async function () {
    // Clear state for each test
    l1Tokens = {};
    destinationChainIds = [];

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

  describe(`Tree with ${REFUND_CHAIN_COUNT} Leaves, each containing refunds for ${REFUND_TOKEN_COUNT} different tokens`, function () {
    beforeEach(async function () {
      const simpleTree = await constructSimpleTree(destinationChainIds, l1Tokens);
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
    });
    it("Executing 1 leaf", async function () {
      const leafIndexToExecute = 0;

      const initiateTxn = await hubPool.connect(dataWorker).proposeRootBundle(
        [consts.mockBundleEvaluationBlockNumbers[0]], // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        1, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
        tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        consts.mockRelayerRefundRoot, // Not relevant for this test.
        consts.mockSlowRelayFulfillmentRoot // Not relevant for this test.
      );
      console.log(`proposeRootBundle-gasUsed: ${(await initiateTxn.wait()).gasUsed}`);

      // Advance time so the request can be executed and execute the request.
      await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
      const txn = await hubPool
        .connect(dataWorker)
        .executeRootBundle(leaves[leafIndexToExecute], tree.getHexProof(leaves[leafIndexToExecute]));

      // Balances should have updated as expected for tokens contained in the first leaf.
      for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
        expect(await l1Tokens[leafIndexToExecute][i].balanceOf(hubPool.address)).to.equal(
          STARTING_LP_AMOUNT.sub(SEND_AMOUNT)
        );
        expect(await l1Tokens[leafIndexToExecute][i].balanceOf(mockAdapter.address)).to.equal(SEND_AMOUNT);
      }

      const receipt = await txn.wait();
      console.log(`executeRootBundle-gasUsed: ${receipt.gasUsed}`);
    });
    it("Executing all leaves", async function () {
      const initiateTxn = await hubPool.connect(dataWorker).proposeRootBundle(
        destinationChainIds, // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        REFUND_CHAIN_COUNT, // poolRebalanceLeafCount. Execute all leaves
        tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        consts.mockRelayerRefundRoot, // Not relevant for this test.
        consts.mockSlowRelayFulfillmentRoot // Not relevant for this test.
      );
      console.log(`proposeRootBundle-gasUsed: ${(await initiateTxn.wait()).gasUsed}`);

      // Advance time so the request can be executed and execute the request.
      await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
      const txns = [];
      for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
        txns.push(await hubPool.connect(dataWorker).executeRootBundle(leaves[i], tree.getHexProof(leaves[i])));
      }

      // Balances should have updated as expected for tokens contained in the first leaf.
      for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
        for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
          expect(await l1Tokens[i][j].balanceOf(hubPool.address)).to.equal(STARTING_LP_AMOUNT.sub(SEND_AMOUNT));
          expect(await l1Tokens[i][j].balanceOf(mockAdapter.address)).to.equal(SEND_AMOUNT);
        }
      }

      // Now that we've verified that the transaction succeeded, let's compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) executeRootBundle-gasUsed: ${gasUsed.div(REFUND_CHAIN_COUNT)}`);
    });
  });
});
