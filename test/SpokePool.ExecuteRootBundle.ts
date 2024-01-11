import { MerkleTree } from "../utils/MerkleTree";
import {
  SignerWithAddress,
  seedContract,
  toBN,
  expect,
  Contract,
  ethers,
  createRandomBytes32,
  getParamType,
  keccak256,
  defaultAbiCoder,
} from "../utils/utils";
import * as consts from "./constants";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";
import { V3RelayerRefundLeaf, buildV3RelayerRefundLeaves, buildV3RelayerRefundTree } from "./MerkleLib.utils";

let spokePool: Contract, destErc20: Contract, weth: Contract;
let dataWorker: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let destinationChainId: number;

describe("SpokePool Root Bundle Execution", function () {
  beforeEach(async function () {
    [dataWorker, relayer, rando] = await ethers.getSigners();
    ({ destErc20, spokePool, weth } = await spokePoolFixture());
    destinationChainId = Number(await spokePool.chainId());

    // Send funds to SpokePool.
    await seedContract(spokePool, dataWorker, [destErc20], weth, consts.amountHeldByPool);
  });

  describe("V3 relayer refund leaves", function () {
    let leaves: V3RelayerRefundLeaf[], tree: MerkleTree<V3RelayerRefundLeaf>;
    beforeEach(async function () {
      leaves = buildV3RelayerRefundLeaves(
        [destinationChainId, destinationChainId], // Destination chain ID.
        [consts.amountToReturn, toBN(0)], // amountToReturn.
        [destErc20.address, destErc20.address], // l2Token.
        [[relayer.address, rando.address], []], // refundAddresses.
        [[consts.amountToRelay, consts.amountToRelay], []], // refundAmounts.
        [createRandomBytes32(), consts.mockTreeRoot], // fillsRefundedRoot.
        [createRandomBytes32(), consts.mockTreeRoot] // fillsRefundedHash.
      );
      tree = await buildV3RelayerRefundTree(leaves);
    });
    it("Happy case: relayer can execute leaf to payout ERC20 tokens from spoke pool", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(() =>
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.changeTokenBalances(
        destErc20,
        [relayer, rando, spokePool],
        [consts.amountToRelay, consts.amountToRelay, consts.amountToRelay.mul(-2)]
      );
    });
    it("calls _preExecuteLeafHook", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0])))
        .to.emit(spokePool, "PreLeafExecuteHook")
        .withArgs(leaves[0].l2TokenAddress);
    });
    it("cannot re-enter", async function () {
      const functionCalldata = spokePool.interface.encodeFunctionData("executeV3RelayerRefundLeaf", [
        0,
        leaves[0],
        tree.getHexProof(leaves[0]),
      ]);
      await expect(spokePool.connect(dataWorker).callback(functionCalldata)).to.be.revertedWith(
        "ReentrancyGuard: reentrant call"
      );
    });
    it("can execute even if fills are paused", async function () {
      await spokePool.pauseFills(true);
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(relayer).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))).to
        .not.be.reverted;
    });
    it("cannot execute leaves with chain IDs not matching spoke pool's chain ID", async function () {
      // In this test, the merkle proof is valid for the tree relayed to the spoke pool, but the merkle leaf
      // destination chain ID does not match the spoke pool's chainId() and therefore cannot be executed.
      const leafWithWrongDestinationChain: V3RelayerRefundLeaf = {
        ...leaves[0],
        chainId: leaves[0].chainId.add(1),
      };
      const treeWithWrongDestinationChain = await buildV3RelayerRefundTree([leafWithWrongDestinationChain]);
      await spokePool
        .connect(dataWorker)
        .relayRootBundle(treeWithWrongDestinationChain.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(
        spokePool
          .connect(dataWorker)
          .executeV3RelayerRefundLeaf(
            0,
            leafWithWrongDestinationChain,
            treeWithWrongDestinationChain.getHexProof(leafWithWrongDestinationChain)
          )
      ).to.be.revertedWith("InvalidChainId");
    });
    it("refund address length mismatch", async function () {
      const invalidLeaf = {
        ...leaves[0],
        refundAddresses: [],
      };
      const paramType = await getParamType("MerkleLibTest", "verifyV3RelayerRefund", "refund");
      const hashFn = (input: V3RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
      const invalidTree = new MerkleTree<V3RelayerRefundLeaf>([invalidLeaf], hashFn);
      await spokePool.connect(dataWorker).relayRootBundle(invalidTree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, invalidLeaf, invalidTree.getHexProof(invalidLeaf))
      ).to.be.revertedWith("InvalidMerkleLeaf");
    });
    it("invalid merkle proof", async function () {
      // Relay two root bundles:
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await spokePool.connect(dataWorker).relayRootBundle(consts.mockSlowRelayRoot, consts.mockSlowRelayRoot);

      // Incorrect root bundle ID
      await expect(
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(
          1, // rootBundleId should be 0
          leaves[0],
          tree.getHexProof(leaves[0])
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect relayer refund leaf for proof
      await expect(
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(
          0,
          leaves[1], // Should be leaves[0]
          tree.getHexProof(leaves[0])
        )
      ).to.revertedWith("InvalidMerkleProof");

      // Incorrect proof
      await expect(
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(
          0,
          leaves[0],
          tree.getHexProof(leaves[1]) // Should be leaves[0]
        )
      ).to.revertedWith("InvalidMerkleProof");
    });
    it("cannot double claim", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));
      await expect(
        spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.be.revertedWith("ClaimedMerkleLeaf");
    });
    it("emits expected events", async function () {
      await spokePool.connect(dataWorker).relayRootBundle(tree.getHexRoot(), consts.mockSlowRelayRoot);
      await expect(spokePool.connect(dataWorker).executeV3RelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0])))
        .to.emit(spokePool, "ExecutedV3RelayerRefundRoot")
        .withArgs(
          leaves[0].amountToReturn,
          leaves[0].chainId,
          leaves[0].refundAmounts,
          0, // rootBundleId
          leaves[0].leafId,
          leaves[0].l2TokenAddress,
          leaves[0].refundAddresses,
          leaves[0].fillsRefundedRoot,
          leaves[0].fillsRefundedHash
        );
    });
  });

  describe("_distributeRelayerRefunds", function () {
    it("refund address length mismatch", async function () {
      await expect(
        spokePool
          .connect(dataWorker)
          .distributeRelayerRefunds(
            destinationChainId,
            toBN(1),
            [consts.amountToRelay, consts.amountToRelay, toBN(0)],
            0,
            destErc20.address,
            [relayer.address, rando.address]
          )
      ).to.be.revertedWith("InvalidMerkleLeaf");
    });
    describe("amountToReturn > 0", function () {
      it("calls _bridgeTokensToHubPool", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(1), [], 0, destErc20.address, [])
        )
          .to.emit(spokePool, "BridgedToHubPool")
          .withArgs(toBN(1), destErc20.address);
      });
      it("emits TokensBridged", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(1), [], 0, destErc20.address, [])
        )
          .to.emit(spokePool, "TokensBridged")
          .withArgs(toBN(1), destinationChainId, 0, destErc20.address);
      });
    });
    describe("amountToReturn = 0", function () {
      it("does not call _bridgeTokensToHubPool", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(0), [], 0, destErc20.address, [])
        ).to.not.emit(spokePool, "BridgedToHubPool");
      });
      it("does not emit TokensBridged", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(destinationChainId, toBN(0), [], 0, destErc20.address, [])
        ).to.not.emit(spokePool, "TokensBridged");
      });
    });
    describe("some refundAmounts > 0", function () {
      it("sends one Transfer per nonzero refundAmount", async function () {
        await expect(() =>
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(
              destinationChainId,
              toBN(1),
              [consts.amountToRelay, consts.amountToRelay, toBN(0)],
              0,
              destErc20.address,
              [relayer.address, rando.address, rando.address]
            )
        ).to.changeTokenBalances(
          destErc20,
          [spokePool, relayer, rando],
          [consts.amountToRelay.mul(-2), consts.amountToRelay, consts.amountToRelay]
        );
        const transferLogCount = (await destErc20.queryFilter(destErc20.filters.Transfer(spokePool.address))).length;
        expect(transferLogCount).to.equal(2);
      });
      it("also bridges tokens to hub pool if amountToReturn > 0", async function () {
        await expect(
          spokePool
            .connect(dataWorker)
            .distributeRelayerRefunds(
              destinationChainId,
              toBN(1),
              [consts.amountToRelay, consts.amountToRelay, toBN(0)],
              0,
              destErc20.address,
              [relayer.address, rando.address, rando.address]
            )
        )
          .to.emit(spokePool, "BridgedToHubPool")
          .withArgs(toBN(1), destErc20.address);
      });
    });
  });
});
