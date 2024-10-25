import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { Test } from "../../target/types/test";
import { assert } from "chai";
import { MerkleTree } from "@uma/common/dist/MerkleTree";
import { ethers } from "ethers";
import { BigNumberish } from "ethers";
import { common } from "./SvmSpoke.Common";
const { assertSE } = common;

function randomAddress(): string {
  const wallet = ethers.Wallet.createRandom();
  return wallet.address;
}
export interface RelayerRefundLeaf {
  amountToReturn: BigNumberish;
  chainId: BigNumberish;
  refundAmounts: BigNumberish[];
  leafId: BigNumberish;
  l2TokenAddress: string;
  refundAddresses: string[];
}

export function randomBigInt(bytes = 32, signed = false) {
  const sign = signed && Math.random() < 0.5 ? "-" : "";
  const byteString = "0x" + Buffer.from(ethers.utils.randomBytes(signed ? bytes - 1 : bytes)).toString("hex");
  return BigInt(sign + byteString);
}

describe("utils.merkle", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.Test as Program<Test>;
  it("Test merkle proof verification Across", async () => {
    const relayerRefundLeaves: RelayerRefundLeaf[] = [];
    const numDistributions = 101; // Create 101 and remove the last to use as the "invalid" one.
    for (let i = 0; i < numDistributions; i++) {
      const numAddresses = 10;
      const refundAddresses: string[] = [];
      const refundAmounts: bigint[] = [];
      for (let j = 0; j < numAddresses; j++) {
        refundAddresses.push(randomAddress());
        refundAmounts.push(randomBigInt());
      }
      relayerRefundLeaves.push({
        leafId: BigInt(i),
        chainId: randomBigInt(2),
        amountToReturn: randomBigInt(),
        l2TokenAddress: randomAddress(),
        refundAddresses,
        refundAmounts,
      });
    }

    // Remove the last element.
    const invalidRelayerRefundLeaf = relayerRefundLeaves.pop()!;

    const abiCoder = new ethers.utils.AbiCoder();
    const hashFn = (input: RelayerRefundLeaf) => {
      const encodedData = abiCoder.encode(
        [
          "tuple(uint256 leafId, uint256 chainId, uint256 amountToReturn, address l2TokenAddress, address[] refundAddresses, uint256[] refundAmounts)",
        ],
        [
          {
            leafId: input.leafId,
            chainId: input.chainId,
            amountToReturn: input.amountToReturn,
            l2TokenAddress: input.l2TokenAddress,
            refundAddresses: input.refundAddresses,
            refundAmounts: input.refundAmounts,
          },
        ]
      );
      return ethers.utils.keccak256(encodedData);
    };
    const merkleTree = new MerkleTree<RelayerRefundLeaf>(relayerRefundLeaves, hashFn);

    const root = merkleTree.getRoot();
    const proof = merkleTree.getProof(relayerRefundLeaves[14]);
    const leaf = ethers.utils.arrayify(hashFn(relayerRefundLeaves[14]));

    // Verify valid leaf
    await program.methods
      .verify(
        Array.from(root),
        Array.from(leaf),
        proof.map((p) => Array.from(p))
      )
      .rpc();

    // Verify that the excluded element fails to generate a proof and fails verification using the proof generated above.
    const invalidLeaf = ethers.utils.arrayify(hashFn(invalidRelayerRefundLeaf));

    try {
      await program.methods
        .verify(
          Array.from(root),
          Array.from(invalidLeaf),
          proof.map((p) => Array.from(p))
        )
        .rpc();
      assert.fail("Should not be able to verify invalid leaf");
    } catch (err: any) {
      assert.instanceOf(err, anchor.AnchorError);
      assertSE(err.error.errorCode.code, "InvalidMerkleProof", "Expected error code InvalidMerkleProof");
    }
  });

  it("Test merkle proof verification Across tx", async () => {
    // In this test we reproduce the merkle proof verification that was done in the Across tx
    // https://optimistic.etherscan.io/tx/0xfecbc7584741615986fcdc54671f9d80ff802893311743c8c8cbe684681e0cf5
    // We are simulating the first executeRelayerRefundLeaf call in the tx

    const root = "0xe3dbb54612a537bd3773c7672094cf542fac507ad790032737271072643df564";
    const rootBuffer = Buffer.from(root.slice(2), "hex");
    const proof = [
      "0xb2b9a11188bce65a7420b941a150ca87cbbda966282a1cce3f4d27d882335db3",
      "0x784bf6ce3abf9467400d275f33d5f17a1bfeda5c723a89d7f30450a06fbba48d",
      "0x4246d917ad480dba79e5e562387d33815e51e17154c05c57beb2039a84a2887b",
      "0xedb009789faae74ad05035d2457f2938c3d2671927f556eff811129a8fa5bfd0",
      "0x15b97cc61cf0599b929bcee98d61049f4dd182741aa7eec24d028f4f2afe52b0",
    ];
    const leaf = "0xd2a692babeae0c3399013cdeeab3c80af382a9203b723fe1fdfb7b35dd30aa5e";
    const leafBuffer = Buffer.from(leaf.slice(2), "hex");
    const proofBuffers = proof.map((p) => Buffer.from(p.slice(2), "hex"));

    // Verify valid leaf
    await program.methods
      .verify(
        Array.from(rootBuffer),
        Array.from(leafBuffer),
        proofBuffers.map((b) => Array.from(b))
      )
      .rpc();
  });
});
