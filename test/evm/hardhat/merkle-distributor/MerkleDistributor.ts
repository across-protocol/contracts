import { ethers, getContractFactory, SignerWithAddress, Contract, toWei, toBN, expect } from "../../../../utils/utils";
import { MAX_UINT_VAL, MerkleTree } from "@uma/common";
import { TokenRolesEnum } from "../constants";

type Recipient = {
  account: string;
  amount: string;
  accountIndex: number;
};

// Contract instances
let merkleDistributor: Contract;
let rewardToken: Contract;

let accounts: SignerWithAddress[];
let contractCreator: SignerWithAddress;
let otherAddress: SignerWithAddress;

// Test variables
let merkleTree: MerkleTree<Buffer>;
const hashFn = (input: Buffer) => input.toString("hex");

let windowIndex: number;
const sampleIpfsHash = "";

const createLeaf = (recipient: Recipient) => {
  expect(Object.keys(recipient).every((val) => ["account", "amount", "accountIndex"].includes(val))).to.be.true;

  return Buffer.from(
    ethers.utils
      .solidityKeccak256(
        ["address", "uint256", "uint256"],
        [recipient.account, recipient.amount, recipient.accountIndex]
      )
      .slice(2),
    "hex"
  );
};

describe("AcrossMerkleDistributor", () => {
  beforeEach(async () => {
    accounts = await ethers.getSigners();
    [contractCreator, otherAddress] = accounts;
    merkleDistributor = await (await getContractFactory("AcrossMerkleDistributor", contractCreator)).deploy();
    rewardToken = await (await getContractFactory("ExpandedERC20", contractCreator)).deploy(`Test Token #1`, `T1`, 18);
    await rewardToken.addMember(TokenRolesEnum.MINTER, contractCreator.address);
    await rewardToken.connect(contractCreator).mint(contractCreator.address, MAX_UINT_VAL);
    await rewardToken.connect(contractCreator).approve(merkleDistributor.address, MAX_UINT_VAL);
  });

  describe("Basic lifecycle", () => {
    it("Only admin can whitelist claimers", async function () {
      await expect(merkleDistributor.connect(otherAddress).whitelistClaimer(otherAddress.address, true)).to.be.reverted;
    });
    it("claim", async () => {
      const totalRewardAmount = toBN(toWei("100")).toString();
      const leaf = createLeaf({
        account: otherAddress.address,
        amount: totalRewardAmount,
        accountIndex: 0,
      });

      merkleTree = new MerkleTree<Buffer>([leaf], hashFn);
      // Expect this merkle root to be at the first index.
      windowIndex = 0;
      // Seed the merkleDistributor with the root of the tree and additional information.
      await merkleDistributor
        .connect(contractCreator)
        .setWindow(totalRewardAmount, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);

      // Only claim recipient can claim
      await expect(
        merkleDistributor.connect(contractCreator).claim({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      ).to.be.revertedWith("invalid claimer");

      const balanceBefore = await rewardToken.balanceOf(otherAddress.address);

      // Claimer can claim:
      await expect(
        merkleDistributor.connect(otherAddress).claim({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      )
        .to.emit(merkleDistributor, "Claimed")
        .withArgs(otherAddress.address, 0, otherAddress.address, 0, totalRewardAmount, rewardToken.address);

      // Balance should be sent to claim recipient.
      expect((await rewardToken.balanceOf(otherAddress.address)).sub(balanceBefore)).to.equal(totalRewardAmount);

      // Cannot claim again
      await expect(
        merkleDistributor.connect(otherAddress).claim({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      ).to.be.revertedWith("Account has already claimed for this window");
    });
    it("claimMulti", async () => {
      const totalRewardAmount = toBN(toWei("100")).toString();
      const leaf1 = createLeaf({
        account: otherAddress.address,
        amount: totalRewardAmount,
        accountIndex: 0,
      });
      const leaf2 = createLeaf({
        account: otherAddress.address,
        amount: totalRewardAmount,
        accountIndex: 1,
      });
      merkleTree = new MerkleTree<Buffer>([leaf1, leaf2], hashFn);
      // Expect this merkle root to be at the first index.
      windowIndex = 0;
      // Seed the merkleDistributor with the root of the tree and additional information.
      await merkleDistributor
        .connect(contractCreator)
        .setWindow(toBN(totalRewardAmount).mul(2), rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);

      const claim1 = {
        windowIndex,
        account: otherAddress.address,
        accountIndex: 0,
        amount: totalRewardAmount,
        merkleProof: merkleTree.getProof(leaf1),
      };
      const claim2 = {
        windowIndex,
        account: otherAddress.address,
        accountIndex: 1,
        amount: totalRewardAmount,
        merkleProof: merkleTree.getProof(leaf2),
      };
      // Only claim recipient can claim
      await expect(merkleDistributor.connect(contractCreator).claimMulti([claim1, claim2])).to.be.revertedWith(
        "invalid claimer"
      );

      const balanceBefore = await rewardToken.balanceOf(otherAddress.address);

      // Claimer can claim:
      await expect(() => merkleDistributor.connect(otherAddress).claimMulti([claim1, claim2])).to.changeTokenBalances(
        rewardToken,
        [otherAddress],
        [toBN(totalRewardAmount).mul(2)]
      );

      // Balance should be sent to claim recipient.
      expect((await rewardToken.balanceOf(otherAddress.address)).sub(balanceBefore)).to.equal(
        toBN(totalRewardAmount).mul(2)
      );

      // Cannot claim again
      await expect(merkleDistributor.connect(otherAddress).claimMulti([claim1, claim2])).to.be.revertedWith(
        "Account has already claimed for this window"
      );
    });
    it("claimFor: events", async () => {
      const totalRewardAmount = toBN(toWei("100")).toString();
      const leaf = createLeaf({
        account: otherAddress.address,
        amount: totalRewardAmount,
        accountIndex: 0,
      });
      merkleTree = new MerkleTree<Buffer>([leaf], hashFn);
      // Expect this merkle root to be at the first index.
      windowIndex = 0;
      // Seed the merkleDistributor with the root of the tree and additional information.
      await merkleDistributor
        .connect(contractCreator)
        .setWindow(totalRewardAmount, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);

      // Only whitelisted caller can claim
      const balanceBefore = await rewardToken.balanceOf(contractCreator.address);
      await expect(
        merkleDistributor.connect(contractCreator).claimFor({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      ).to.be.revertedWith("unwhitelisted claimer");

      // Whitelisted claimer can claim:
      await merkleDistributor.whitelistClaimer(contractCreator.address, true);

      // Can claim on behalf of another user
      await expect(
        merkleDistributor.connect(contractCreator).claimFor({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      )
        .to.emit(merkleDistributor, "Claimed")
        .withArgs(contractCreator.address, 0, otherAddress.address, 0, totalRewardAmount, rewardToken.address);

      // Balance should be sent to whitelited claimer, not claim recipient.
      expect((await rewardToken.balanceOf(contractCreator.address)).sub(balanceBefore)).to.equal(totalRewardAmount);
      expect(await rewardToken.balanceOf(otherAddress.address)).to.equal(0);

      // Cannot claim again
      await expect(
        merkleDistributor.connect(contractCreator).claimFor({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      ).to.be.revertedWith("Account has already claimed for this window");

      // Can unwhitelist claimer
      await merkleDistributor.whitelistClaimer(contractCreator.address, false);
      await expect(
        merkleDistributor.connect(contractCreator).claimFor({
          windowIndex,
          account: otherAddress.address,
          accountIndex: 0,
          amount: totalRewardAmount,
          merkleProof: merkleTree.getProof(leaf),
        })
      ).to.be.revertedWith("unwhitelisted claimer");

      // Emits ClaimFor event
      const eventFilter = merkleDistributor.filters.ClaimFor;
      const events = await merkleDistributor.queryFilter(eventFilter());
      expect(events[0]?.args?.caller).to.equal(contractCreator.address);
      expect(events[0]?.args?.account).to.equal(otherAddress.address);
    });
  });
});
