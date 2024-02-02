import { PoolRebalanceLeaf, RelayerRefundLeaf, V3RelayerRefundLeaf } from "./MerkleLib.utils";
import { merkleLibFixture } from "./fixtures/MerkleLib.Fixture";
import { MerkleTree, EMPTY_MERKLE_ROOT } from "../utils/MerkleTree";
import {
  expect,
  randomBigNumber,
  randomAddress,
  getParamType,
  defaultAbiCoder,
  keccak256,
  Contract,
  BigNumber,
  createRandomBytes32,
  ethers,
} from "../utils/utils";
import { V3RelayData, V3SlowFill } from "../test-utils";

let merkleLibTest: Contract;

describe("MerkleLib Proofs", async function () {
  before(async function () {
    ({ merkleLibTest } = await merkleLibFixture());
  });

  it("Empty tree", async function () {
    const paramType = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
    const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));

    // Can construct empty tree without error.
    const merkleTree = new MerkleTree<PoolRebalanceLeaf>([], hashFn);

    // Returns hardcoded root for empty tree.
    expect(merkleTree.getHexRoot()).to.equal(EMPTY_MERKLE_ROOT);
  });
  it("PoolRebalanceLeaf Proof", async function () {
    const poolRebalanceLeaves: PoolRebalanceLeaf[] = [];
    const numRebalances = 101;
    for (let i = 0; i < numRebalances; i++) {
      const numTokens = 10;
      const l1Tokens: string[] = [];
      const bundleLpFees: BigNumber[] = [];
      const netSendAmounts: BigNumber[] = [];
      const runningBalances: BigNumber[] = [];
      for (let j = 0; j < numTokens; j++) {
        l1Tokens.push(randomAddress());
        bundleLpFees.push(randomBigNumber());
        netSendAmounts.push(randomBigNumber(undefined, true));
        runningBalances.push(randomBigNumber(undefined, true));
      }
      poolRebalanceLeaves.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(),
        l1Tokens,
        bundleLpFees,
        netSendAmounts,
        runningBalances,
        groupIndex: BigNumber.from(0),
      });
    }

    // Remove the last element.
    const invalidPoolRebalanceLeaf = poolRebalanceLeaves.pop()!;

    const paramType = await getParamType("MerkleLibTest", "verifyPoolRebalance", "rebalance");
    const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<PoolRebalanceLeaf>(poolRebalanceLeaves, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(poolRebalanceLeaves[34]);
    expect(await merkleLibTest.verifyPoolRebalance(root, poolRebalanceLeaves[34], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidPoolRebalanceLeaf)).to.throw();
    expect(await merkleLibTest.verifyPoolRebalance(root, invalidPoolRebalanceLeaf, proof)).to.equal(false);
  });
  it("RelayerRefundLeafProof", async function () {
    const relayerRefundLeaves: RelayerRefundLeaf[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses: string[] = [];
      const refundAmounts: BigNumber[] = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push(randomAddress());
        refundAmounts.push(randomBigNumber());
      }
      relayerRefundLeaves.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(2),
        amountToReturn: randomBigNumber(),
        l2TokenAddress: randomAddress(),
        refundAddresses,
        refundAmounts,
      });
    }

    // Remove the last element.
    const invalidRelayerRefundLeaf = relayerRefundLeaves.pop()!;

    const paramType = await getParamType("MerkleLibTest", "verifyRelayerRefund", "refund");
    const hashFn = (input: RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<RelayerRefundLeaf>(relayerRefundLeaves, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(relayerRefundLeaves[14]);
    expect(await merkleLibTest.verifyRelayerRefund(root, relayerRefundLeaves[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidRelayerRefundLeaf)).to.throw();
    expect(await merkleLibTest.verifyRelayerRefund(root, invalidRelayerRefundLeaf, proof)).to.equal(false);
  });
  it("V3RelayerRefundLeafProof", async function () {
    const relayerRefundLeaves: V3RelayerRefundLeaf[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses: string[] = [];
      const refundAmounts: BigNumber[] = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push(randomAddress());
        refundAmounts.push(randomBigNumber());
      }
      relayerRefundLeaves.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(2),
        amountToReturn: randomBigNumber(),
        l2TokenAddress: randomAddress(),
        refundAddresses,
        refundAmounts,
        fillsRefundedRoot: createRandomBytes32(),
        fillsRefundedHash: createRandomBytes32(),
      });
    }

    // Remove the last element.
    const invalidRelayerRefundLeaf = relayerRefundLeaves.pop()!;

    const paramType = await getParamType("MerkleLibTest", "verifyV3RelayerRefund", "refund");
    const hashFn = (input: V3RelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<V3RelayerRefundLeaf>(relayerRefundLeaves, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(relayerRefundLeaves[14]);
    expect(await merkleLibTest.verifyV3RelayerRefund(root, relayerRefundLeaves[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidRelayerRefundLeaf)).to.throw();
    expect(await merkleLibTest.verifyV3RelayerRefund(root, invalidRelayerRefundLeaf, proof)).to.equal(false);
  });
  it("V3SlowFillProof", async function () {
    const slowFillLeaves: V3SlowFill[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const relayData: V3RelayData = {
        depositor: randomAddress(),
        recipient: randomAddress(),
        exclusiveRelayer: randomAddress(),
        inputToken: randomAddress(),
        outputToken: randomAddress(),
        inputAmount: randomBigNumber(),
        outputAmount: randomBigNumber(),
        originChainId: randomBigNumber(2).toNumber(),
        depositId: BigNumber.from(i).toNumber(),
        fillDeadline: randomBigNumber(2).toNumber(),
        exclusivityDeadline: randomBigNumber(2).toNumber(),
        message: ethers.utils.hexlify(ethers.utils.randomBytes(1024)),
      };
      slowFillLeaves.push({
        relayData,
        chainId: randomBigNumber(2).toNumber(),
        updatedOutputAmount: relayData.outputAmount,
      });
    }

    // Remove the last element.
    const invalidLeaf = slowFillLeaves.pop()!;

    const paramType = await getParamType("MerkleLibTest", "verifyV3SlowRelayFulfillment", "slowFill");
    const hashFn = (input: V3SlowFill) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<V3SlowFill>(slowFillLeaves, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(slowFillLeaves[14]);
    expect(await merkleLibTest.verifyV3SlowRelayFulfillment(root, slowFillLeaves[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidLeaf)).to.throw();
    expect(await merkleLibTest.verifyV3SlowRelayFulfillment(root, invalidLeaf, proof)).to.equal(false);
  });
});
