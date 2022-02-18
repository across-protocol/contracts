import { PoolRebalanceLeaf, DestinationDistributionLeaf } from "./MerkleLib.utils";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { MerkleTree } from "../utils/MerkleTree";
import { expect, randomBigNumber, randomAddress, getParamType, defaultAbiCoder } from "./utils";
import { keccak256, Contract, BigNumber } from "./utils";

let merkleLibTest: Contract;

describe("MerkleLib Proofs", async function () {
  before(async function () {
    ({ merkleLibTest } = await merkleLibFixture());
  });

  it("PoolRebalanceLeaf Proof", async function () {
    const poolRebalanceLeafs: PoolRebalanceLeaf[] = [];
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
        netSendAmounts.push(randomBigNumber());
        runningBalances.push(randomBigNumber());
      }
      poolRebalanceLeafs.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(),
        l1Tokens,
        bundleLpFees,
        netSendAmounts,
        runningBalances,
      });
    }

    // Remove the last element.
    const invalidPoolRebalanceLeaf = poolRebalanceLeafs.pop()!;

    const paramType = await getParamType("MerkleLib", "verifyPoolRebalance", "rebalance");
    const hashFn = (input: PoolRebalanceLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<PoolRebalanceLeaf>(poolRebalanceLeafs, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(poolRebalanceLeafs[34]);
    expect(await merkleLibTest.verifyPoolRebalance(root, poolRebalanceLeafs[34], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidPoolRebalanceLeaf)).to.throw();
    expect(await merkleLibTest.verifyPoolRebalance(root, invalidPoolRebalanceLeaf, proof)).to.equal(false);
  });
  it("DestinationDistributionLeafProof", async function () {
    const destinationDistributionLeafs: DestinationDistributionLeaf[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses: string[] = [];
      const refundAmounts: BigNumber[] = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push(randomAddress());
        refundAmounts.push(randomBigNumber());
      }
      destinationDistributionLeafs.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(2),
        amountToReturn: randomBigNumber(),
        l2TokenAddress: randomAddress(),
        refundAddresses,
        refundAmounts,
      });
    }

    // Remove the last element.
    const invalidDestinationDistributionLeaf = destinationDistributionLeafs.pop()!;

    const paramType = await getParamType("MerkleLib", "verifyRelayerDistribution", "distribution");
    const hashFn = (input: DestinationDistributionLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<DestinationDistributionLeaf>(destinationDistributionLeafs, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(destinationDistributionLeafs[14]);
    expect(await merkleLibTest.verifyRelayerDistribution(root, destinationDistributionLeafs[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidDestinationDistributionLeaf)).to.throw();
    expect(await merkleLibTest.verifyRelayerDistribution(root, invalidDestinationDistributionLeaf, proof)).to.equal(
      false
    );
  });
});
