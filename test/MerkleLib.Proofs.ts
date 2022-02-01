import { expect } from "chai";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { Contract, BigNumber } from "ethers";
import { MerkleTree } from "../utils/MerkleTree";
import { ethers } from "hardhat";

interface PoolRebalance {
  leafId: BigNumber;
  chainId: BigNumber;
  tokenAddresses: string[];
  bundleLpFees: BigNumber[];
  netSendAmount: BigNumber[];
  runningBalance: BigNumber[];
}

interface DestinationDistribution {
  leafId: BigNumber;
  chainId: BigNumber;
  amountToReturn: BigNumber;
  l2TokenAddress: string;
  refundAddresses: string[];
  refundAmounts: BigNumber[];
}

function randomBigNumber() {
  return ethers.BigNumber.from(ethers.utils.randomBytes(31));
}

function randomAddress() {
  return ethers.utils.hexlify(ethers.utils.randomBytes(20));
}

describe("MerkleLib Claims", async function () {
  let merkleLibTest: Contract;
  before(async function () {
    ({ merkleLibTest } = await merkleLibFixture());
  });

  it("PoolRebalance Proof", async function () {
    const poolRebalances: PoolRebalance[] = [];
    const numRebalances = 100;
    for (let i = 0; i < numRebalances; i++) {
      const numTokens = 10;
      const tokenAddresses: string[] = [];
      const bundleLpFees: BigNumber[] = [];
      const netSendAmount: BigNumber[] = [];
      const runningBalance: BigNumber[] = [];
      for (let j = 0; j < numTokens; j++) {
        tokenAddresses.push(randomAddress());
        bundleLpFees.push(randomBigNumber());
        netSendAmount.push(randomBigNumber());
        runningBalance.push(randomBigNumber());
      }
      poolRebalances.push({
        leafId: BigNumber.from(i),
        chainId: randomBigNumber(),
        tokenAddresses,
        bundleLpFees,
        netSendAmount,
        runningBalance,
      });
    }

    const fragment = merkleLibTest.interface.fragments.find((fragment) => fragment.name === "verifyRebalance");
    const param = fragment!.inputs.find((input) => input.name === "rebalance");

    const hashFn = (input: PoolRebalance) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([param!], [input]));
    const merkleTree = new MerkleTree<PoolRebalance>(poolRebalances, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(poolRebalances[34]);
    expect(await merkleLibTest.verifyRebalance(root, poolRebalances[34], proof)).to.equal(true);
  });
  it("DestinationDistributionProofs", async function () {
    const destinationDistributions: DestinationDistribution[] = [];
    const numDistributions = 100;
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

    const fragment = merkleLibTest.interface.fragments.find((fragment) => fragment.name === "verifyDistribution");
    const param = fragment!.inputs.find((input) => input.name === "distribution");

    const hashFn = (input: DestinationDistribution) =>
      ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode([param!], [input]));
    const merkleTree = new MerkleTree<DestinationDistribution>(destinationDistributions, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(destinationDistributions[14]);
    expect(await merkleLibTest.verifyDistribution(root, destinationDistributions[14], proof)).to.equal(true);
  });
});
