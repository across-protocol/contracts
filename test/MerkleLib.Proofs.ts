import { PoolRebalanceLeaf, RelayerRefundLeaf, USSRelayerRefundLeaf } from "./MerkleLib.utils";
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
} from "../utils/utils";

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
  it("USSRelayerRefundLeafProof", async function () {
    const relayerRefundLeaves: USSRelayerRefundLeaf[] = [];
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

    const paramType = await getParamType("MerkleLibTest", "verifyUSSRelayerRefund", "refund");
    const hashFn = (input: USSRelayerRefundLeaf) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<USSRelayerRefundLeaf>(relayerRefundLeaves, hashFn);

    const root = merkleTree.getHexRoot();
    const proof = merkleTree.getHexProof(relayerRefundLeaves[14]);
    expect(await merkleLibTest.verifyUSSRelayerRefund(root, relayerRefundLeaves[14], proof)).to.equal(true);

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    expect(() => merkleTree.getHexProof(invalidRelayerRefundLeaf)).to.throw();
    expect(await merkleLibTest.verifyUSSRelayerRefund(root, invalidRelayerRefundLeaf, proof)).to.equal(false);
  });
});
