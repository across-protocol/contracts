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
  createRandomBytes32,
} from "../utils";
import * as consts from "../constants";
import { TokenRolesEnum, ZERO_ADDRESS } from "@uma/common";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { buildPoolRebalanceLeafTree, buildPoolRebalanceLeafs, PoolRebalanceLeaf } from "../MerkleLib.utils";
import { MerkleTree } from "../../utils/MerkleTree";

require("dotenv").config();

let hubPool: Contract, timer: Contract, weth: Contract, mockAdapter: Contract, mockSpoke: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;

// Associates an array of L1 tokens to sends refunds for to each chain ID.
let l1Tokens: Contract[];
let destinationChainIds: number[];
let leaves: PoolRebalanceLeaf[];
let tree: MerkleTree<PoolRebalanceLeaf>;

// Constants caller can tune to modify gas tests
const REFUND_TOKEN_COUNT = 10;
const REFUND_CHAIN_COUNT = 10;
const SEND_AMOUNT = toBNWei("10");
const STARTING_LP_AMOUNT = SEND_AMOUNT.mul(100); // This should be >= `SEND_AMOUNT` otherwise some relays will revert because
// the pool balance won't be sufficient to cover the relay.
const LP_FEE = SEND_AMOUNT.div(toBN(10));

async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(TokenRolesEnum.MINTER, owner.address);
  return erc20;
}

// Construct tree with REFUND_CHAIN_COUNT leaves, each containing REFUND_TOKEN_COUNT sends
async function constructSimpleTree(_destinationChainIds: number[], _l1Tokens: Contract[]) {
  const _bundleLpFeeAmounts: BigNumber[][] = [];
  const _netSendAmounts: BigNumber[][] = [];
  const _l1TokenAddresses: string[][] = [];
  for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
    _bundleLpFeeAmounts[i] = [];
    _netSendAmounts[i] = [];
    _l1TokenAddresses[i] = [];
    for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
      _bundleLpFeeAmounts[i].push(LP_FEE);
      _netSendAmounts[i].push(SEND_AMOUNT);
      _l1TokenAddresses[i].push(_l1Tokens[j].address);
    }
  }
  const leaves = buildPoolRebalanceLeafs(
    _destinationChainIds,
    _l1TokenAddresses,
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
    destinationChainIds = [];

    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ hubPool, timer, weth, mockSpoke, mockAdapter } = await hubPoolFixture());

    // Seed data worker with bond tokens.
    await seedWallet(dataWorker, [], weth, consts.bondAmount.mul(10));
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    // Deploy test tokens for each chain ID
    l1Tokens = [];
    for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
      const _l1Token = await deployErc20(owner, `Test Token #${i}`, `T-${i}`);
      l1Tokens.push(_l1Token);

      // Mint data worker amount of tokens needed to bond a new root
      await seedWallet(dataWorker, [_l1Token], undefined, consts.bondAmount.mul(100));
      await _l1Token.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(100));

      // Mint LP amount of tokens needed to cover relay
      await seedWallet(liquidityProvider, [_l1Token], undefined, STARTING_LP_AMOUNT);
      await enableTokensForLP(owner, hubPool, weth, [_l1Token]);
      await _l1Token.connect(liquidityProvider).approve(hubPool.address, STARTING_LP_AMOUNT);
      await hubPool.connect(liquidityProvider).addLiquidity(_l1Token.address, STARTING_LP_AMOUNT);
    }

    const adapter = await (await getContractFactory("Ethereum_Adapter", owner)).deploy(hubPool.address);
    const spoke = await (
      await getContractFactory("MockSpokePool", owner)
    ).deploy(randomAddress(), hubPool.address, randomAddress(), ZERO_ADDRESS);
    await hubPool.setCrossChainContracts(1, adapter.address, spoke.address);

    for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
      const adapter = await (await getContractFactory("Ethereum_Adapter", owner)).deploy(hubPool.address);
      const spoke = await (
        await getContractFactory("MockSpokePool", owner)
      ).deploy(randomAddress(), hubPool.address, randomAddress(), ZERO_ADDRESS);
      await hubPool.setCrossChainContracts(i, adapter.address, spoke.address);
      // Just whitelist route from mainnet to l2 (hacky), which shouldn't change gas estimates, but will allow refunds to be sent.
      await Promise.all(
        l1Tokens.map(async (token) => {
          await hubPool.whitelistRoute(1, i, token.address, randomAddress());
        })
      );
      destinationChainIds.push(i);
    }
  });

  describe(`Tree with ${REFUND_CHAIN_COUNT} Leaves, each containing refunds for ${REFUND_TOKEN_COUNT} different tokens`, function () {
    beforeEach(async function () {
      // Add extra token to make the root different.
      const initTree = await constructSimpleTree([...destinationChainIds], [...l1Tokens]);

      await hubPool.connect(dataWorker).proposeRootBundle(
        destinationChainIds, // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        REFUND_CHAIN_COUNT, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
        initTree.tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        createRandomBytes32(),
        createRandomBytes32()
      );

      // Advance time so the request can be executed and execute the request.
      await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
      for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
        await hubPool
          .connect(dataWorker)
          .executeRootBundle(initTree.leaves[i], initTree.tree.getHexProof(initTree.leaves[i]));
      }

      const simpleTree = await constructSimpleTree(destinationChainIds, l1Tokens);
      leaves = simpleTree.leaves;
      tree = simpleTree.tree;
    });

    it("Simple proposal", async function () {
      const initiateTxn = await hubPool.connect(dataWorker).proposeRootBundle(
        destinationChainIds, // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        REFUND_CHAIN_COUNT, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
        createRandomBytes32(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        createRandomBytes32(), // Not relevant for this test.
        createRandomBytes32() // Not relevant for this test.
      );
      console.log(`proposeRootBundle-gasUsed: ${(await initiateTxn.wait()).gasUsed}`);
    });

    it("Executing 1 leaf", async function () {
      const leafIndexToExecute = 0;

      await hubPool.connect(dataWorker).proposeRootBundle(
        [consts.mockBundleEvaluationBlockNumbers[0]], // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        1, // poolRebalanceLeafCount. There is exactly one leaf in the bundle.
        tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        consts.mockRelayerRefundRoot, // Not relevant for this test.
        consts.mockSlowRelayRoot // Not relevant for this test.
      );

      // Advance time so the request can be executed and execute the request.
      await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
      const txn = await hubPool
        .connect(dataWorker)
        .executeRootBundle(leaves[leafIndexToExecute], tree.getHexProof(leaves[leafIndexToExecute]));

      // // Balances should have updated as expected for tokens contained in the first leaf.
      // for (let i = 0; i < REFUND_TOKEN_COUNT; i++) {
      //   expect(await l1Tokens[i].balanceOf(hubPool.address)).to.equal(
      //     STARTING_LP_AMOUNT.sub(SEND_AMOUNT)
      //   );
      //   expect(await l1Tokens[leafIndexToExecute][i].balanceOf(mockAdapter.address)).to.equal(SEND_AMOUNT);
      // }

      const receipt = await txn.wait();
      console.log(`executeRootBundle-gasUsed: ${receipt.gasUsed}`);
    });
    it("Executing all leaves", async function () {
      await hubPool.connect(dataWorker).proposeRootBundle(
        destinationChainIds, // bundleEvaluationBlockNumbers used by bots to construct bundles. Length must equal the number of leafs.
        REFUND_CHAIN_COUNT, // poolRebalanceLeafCount. Execute all leaves
        tree.getHexRoot(), // poolRebalanceRoot. Generated from the merkle tree constructed before.
        consts.mockRelayerRefundRoot, // Not relevant for this test.
        consts.mockSlowRelayRoot // Not relevant for this test.
      );

      // Advance time so the request can be executed and execute the request.
      await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);
      const txns = [];
      for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
        txns.push(await hubPool.connect(dataWorker).executeRootBundle(leaves[i], tree.getHexProof(leaves[i])));
      }

      // // Balances should have updated as expected for tokens contained in the first leaf.
      // for (let i = 0; i < REFUND_CHAIN_COUNT; i++) {
      //   for (let j = 0; j < REFUND_TOKEN_COUNT; j++) {
      //     expect(await l1Tokens[i][j].balanceOf(hubPool.address)).to.equal(STARTING_LP_AMOUNT.sub(SEND_AMOUNT));
      //     expect(await l1Tokens[i][j].balanceOf(mockAdapter.address)).to.equal(SEND_AMOUNT);
      //   }
      // }

      // Now that we've verified that the transaction succeeded, let's compute average gas costs.
      const receipts = await Promise.all(txns.map((_txn) => _txn.wait()));
      const gasUsed = receipts.map((_receipt) => _receipt.gasUsed).reduce((x, y) => x.add(y));
      console.log(`(average) executeRootBundle-gasUsed: ${gasUsed.div(REFUND_CHAIN_COUNT)}`);
    });
  });
});
