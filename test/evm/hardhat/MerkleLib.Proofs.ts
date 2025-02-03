import { PoolRebalanceLeaf, RelayerRefundLeaf } from "./MerkleLib.utils";
import { merkleLibFixture } from "./fixtures/MerkleLib.Fixture";
import { MerkleTree, EMPTY_MERKLE_ROOT } from "../../../utils/MerkleTree";
import {
  expect,
  randomBigNumber,
  randomAddress,
  getParamType,
  defaultAbiCoder,
  keccak256,
  Contract,
  BigNumber,
  ethers,
  randomBytes32,
  bytes32ToAddress,
} from "../../../utils/utils";
import { V3RelayData, V3SlowFill } from "../../../test-utils";
import { ParamType } from "ethers/lib/utils";

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
  it("V3SlowFillProof", async function () {
    const slowFillLeaves: V3SlowFill[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const relayData: V3RelayData = {
        depositor: randomBytes32(),
        recipient: randomBytes32(),
        exclusiveRelayer: randomBytes32(),
        inputToken: randomBytes32(),
        outputToken: randomBytes32(),
        inputAmount: randomBigNumber(),
        outputAmount: randomBigNumber(),
        originChainId: randomBigNumber(2).toNumber(),
        depositId: BigNumber.from(i),
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
  it("Legacy V3SlowFill produces the same MerkleLeaf", async function () {
    const chainId = randomBigNumber(2).toNumber();
    const relayData: V3RelayData = {
      depositor: randomBytes32(),
      recipient: randomBytes32(),
      exclusiveRelayer: randomBytes32(),
      inputToken: randomBytes32(),
      outputToken: randomBytes32(),
      inputAmount: randomBigNumber(),
      outputAmount: randomBigNumber(),
      originChainId: randomBigNumber(2).toNumber(),
      depositId: randomBigNumber(2),
      fillDeadline: randomBigNumber(2).toNumber(),
      exclusivityDeadline: randomBigNumber(2).toNumber(),
      message: ethers.utils.hexlify(ethers.utils.randomBytes(1024)),
    };
    const slowLeaf: V3SlowFill = {
      relayData,
      chainId,
      updatedOutputAmount: relayData.outputAmount,
    };
    const legacyRelayData: V3RelayData = {
      ...relayData,
      depositor: bytes32ToAddress(relayData.depositor),
      recipient: bytes32ToAddress(relayData.recipient),
      exclusiveRelayer: bytes32ToAddress(relayData.exclusiveRelayer),
      inputToken: bytes32ToAddress(relayData.inputToken),
      outputToken: bytes32ToAddress(relayData.outputToken),
    };
    const legacySlowLeaf: V3SlowFill = {
      relayData: legacyRelayData,
      chainId: slowLeaf.chainId,
      updatedOutputAmount: slowLeaf.updatedOutputAmount,
    };

    const paramType = await getParamType("MerkleLibTest", "verifyV3SlowRelayFulfillment", "slowFill");
    const hashFn = (input: V3SlowFill) => keccak256(defaultAbiCoder.encode([paramType!], [input]));
    const merkleTree = new MerkleTree<V3SlowFill>([slowLeaf], hashFn);
    const root = merkleTree.getHexRoot();

    const legacyHashFn = (input: V3SlowFill) =>
      keccak256(
        defaultAbiCoder.encode(
          [
            "tuple(" +
              "tuple(address depositor, address recipient, address exclusiveRelayer, address inputToken, address outputToken, uint256 inputAmount, uint256 outputAmount, uint256 originChainId, uint32 depositId, uint32 fillDeadline, uint32 exclusivityDeadline, bytes message) relayData," +
              "uint256 chainId," +
              "uint256 updatedOutputAmount" +
              ")",
          ],
          [input]
        )
      );
    const merkleTreeLegacy = new MerkleTree<V3SlowFill>([legacySlowLeaf], legacyHashFn);
    const legacyRoot = merkleTreeLegacy.getHexRoot();

    expect(legacyRoot).to.equal(root);
  });
});
