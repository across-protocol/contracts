import { PoolRebalance, DestinationDistribution } from "./MerkleLib.utils";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { MerkleTree } from "../utils/MerkleTree";

import {
  expect,
  randomBigNumber,
  randomAddress,
  getParamType,
  defaultAbiCoder,
  keccak256,
  Contract,
  BigNumber,
} from "./utils";

let merkleLibTest: Contract;

describe("MerkleLib Proofs", async function () {
  before(async function () {
    ({ merkleLibTest } = await merkleLibFixture());
  });

  it("PoolRebalance Proof", async function () {
    const poolRebalances: PoolRebalance[] = [];
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
      poolRebalances.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(),
        l1Tokens,
        bundleLpFees,
        netSendAmounts,
        runningBalances,
      });
    }

    // Remove the last element.
    const invalidPoolRebalance = poolRebalances.pop()!;

    const paramType = await getParamType("MerkleLib", "verifyPoolRebalance", "rebalance");
    const hashFn = (input: PoolRebalance) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<PoolRebalance>(poolRebalances, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(poolRebalances[34]);
    expect(await merkleLibTest.verifyPoolRebalance(root, poolRebalances[34], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidPoolRebalance)).to.throw();
    expect(await merkleLibTest.verifyPoolRebalance(root, invalidPoolRebalance, proof)).to.equal(false);
  });
  it("DestinationDistributionProof", async function () {
    const destinationDistributions: DestinationDistribution[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses: string[] = [];
      const refundAmounts: BigNumber[] = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push(randomAddress());
        refundAmounts.push(randomBigNumber());
      }
      destinationDistributions.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(),
        amountToReturn: randomBigNumber(),
        l2TokenAddress: randomAddress(),
        refundAddresses,
        refundAmounts,
      });
    }

    // Remove the last element.
    const invalidDestinationDistribution = destinationDistributions.pop()!;

    const paramType = await getParamType("MerkleLib", "verifyRelayerDistribution", "distribution");
    const hashFn = (input: DestinationDistribution) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<DestinationDistribution>(destinationDistributions, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(destinationDistributions[14]);
    expect(await merkleLibTest.verifyRelayerDistribution(root, destinationDistributions[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidDestinationDistribution)).to.throw();
    expect(await merkleLibTest.verifyRelayerDistribution(root, invalidDestinationDistribution, proof)).to.equal(false);
  });
});
