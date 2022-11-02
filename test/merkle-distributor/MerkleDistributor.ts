/* eslint-disable no-unused-expressions */

import SamplePayouts from "./SamplePayout.json";
import {
  ethers,
  getContractFactory,
  SignerWithAddress,
  Contract,
  toWei,
  toBN,
  BigNumber,
  utf8ToHex,
  expect,
} from "../utils";
import { MerkleTree } from "@uma/merkle-distributor";
import { deployErc20 } from "../gas-analytics/utils";
import { MAX_UINT_VAL } from "@uma/common";

type Recipient = {
  account: string;
  amount: string;
  accountIndex: number;
};

type RecipientWithProof = Recipient & {
  windowIndex: number;
  merkleProof: Buffer[];
};

type RecipientWithLeaf = Recipient & {
  leaf: Buffer;
};

// Contract instances
let merkleDistributor: Contract;
let rewardToken: Contract;

let accounts: SignerWithAddress[];
let contractCreator: SignerWithAddress;
let otherAddress: SignerWithAddress;

// Test variables
let rewardRecipients: Recipient[];
let recipientsWithLeafs: RecipientWithLeaf[];
let merkleTree: MerkleTree;
let rewardLeafs: (Recipient & { leaf: Buffer })[];
let leaf: Recipient & { leaf: Buffer };
let windowIndex: number;
let claimerProof: Buffer[];
const sampleIpfsHash = "";

const createRewardRecipientsFromSampleData = (jsonPayouts: any): Recipient[] => {
  return Object.keys(jsonPayouts.recipients).map((recipientAddress, idx) => {
    return {
      account: recipientAddress,
      amount: jsonPayouts.recipients[recipientAddress],
      accountIndex: idx,
    };
  });
};

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

describe("MerkleDistributor", () => {
  beforeEach(async () => {
    accounts = await ethers.getSigners();
    [contractCreator, otherAddress] = accounts;
    merkleDistributor = await (await getContractFactory("AcrossMerkleDistributor", contractCreator)).deploy();
    rewardToken = await deployErc20(contractCreator, `Test Token #1`, `T1`);
    await rewardToken.connect(contractCreator).mint(contractCreator.address, MAX_UINT_VAL);
    await rewardToken.connect(contractCreator).approve(merkleDistributor.address, MAX_UINT_VAL);
    await merkleDistributor.connect(contractCreator).whitelistClaimer(contractCreator.address, true);
    await merkleDistributor.connect(contractCreator).whitelistClaimer(otherAddress.address, true);
  });

  describe("Deployment", () => {
    it("contracts should be deployed", () => {
      expect(merkleDistributor.address).to.be.a("string");
      expect(rewardToken.address).to.be.a("string");
    });
  });

  describe("Basic lifecycle", () => {
    it("Only admin can whitelist claimers", async function () {
      await expect(merkleDistributor.connect(otherAddress).whitelistClaimer(otherAddress.address, true)).to.be.reverted;
    });
    it("should create a single, simple tree, seed the distributor and claim rewards", async () => {
      const _rewardRecipients: [SignerWithAddress, BigNumber, number][] = [
        [accounts[3], toBN(toWei("100")), 3],
        [accounts[4], toBN(toWei("200")), 4],
        [accounts[5], toBN(toWei("300")), 5],
      ];
      let totalRewardAmount = toBN(0);
      rewardRecipients = _rewardRecipients.map((_rewardObj) => {
        totalRewardAmount = totalRewardAmount.add(_rewardObj[1]);
        return {
          account: _rewardObj[0].address,
          amount: _rewardObj[1].toString(),
          accountIndex: _rewardObj[2],
        };
      });
      // Generate leafs for each recipient. This is simply the hash of each component of the payout from above.
      recipientsWithLeafs = rewardRecipients.map((item) => ({ ...item, leaf: createLeaf(item) }));
      // Build the merkle tree from an array of hashes from each recipient.
      merkleTree = new MerkleTree(recipientsWithLeafs.map((item) => item.leaf));
      // Expect this merkle root to be at the first index.
      windowIndex = 0;
      // Seed the merkleDistributor with the root of the tree and additional information.
      const seedTx = merkleDistributor
        .connect(contractCreator)
        .setWindow(totalRewardAmount, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);
      // Check event logs.
      await expect(seedTx)
        .to.emit(merkleDistributor, "CreatedWindow")
        .withArgs(windowIndex, totalRewardAmount, rewardToken.address, contractCreator.address);
      // Check on chain Window state:
      const windowState = await merkleDistributor.merkleWindows(windowIndex);
      expect(windowState.merkleRoot).to.eq("0x" + merkleTree.getRoot().toString("hex"));
      expect(windowState.remainingAmount).to.eq(totalRewardAmount.toString());
      expect(windowState.rewardToken).to.eq(rewardToken.address);
      expect(windowState.ipfsHash).to.eq(sampleIpfsHash);
      // Check that next created index has incremented.
      expect((await merkleDistributor.nextCreatedIndex()).toString()).to.eq((windowIndex + 1).toString());
      // Claim for all accounts
      for (const recipient of recipientsWithLeafs) {
        claimerProof = merkleTree.getProof(recipient.leaf);
        const claimerBalancerBefore = toBN(await rewardToken.balanceOf(recipient.account));
        const contractBalancerBefore = toBN(await rewardToken.balanceOf(merkleDistributor.address));
        const remainingAmountBefore = toBN((await merkleDistributor.merkleWindows(windowIndex)).remainingAmount);
        // Claim the rewards, providing the information needed to re-build the tree & verify the proof.
        // Note: Anyone can claim on behalf of anyone else.
        let claimTx = merkleDistributor.connect(contractCreator).claim({
          windowIndex,
          account: recipient.account,
          accountIndex: recipient.accountIndex,
          amount: recipient.amount,
          merkleProof: claimerProof,
        });
        await expect(claimTx)
          .to.emit(merkleDistributor, "Claimed")
          .withArgs(
            contractCreator.address,
            windowIndex.toString(),
            recipient.account,
            recipient.accountIndex.toString(),
            recipient.amount,
            rewardToken.address
          );
        // Claimer balance should have increased by the amount of the reward.
        expect(await rewardToken.balanceOf(recipient.account)).to.eq(claimerBalancerBefore.add(toBN(recipient.amount)));
        // Contract balance should have decreased by reward amount.
        expect(await rewardToken.balanceOf(merkleDistributor.address)).to.eq(
          contractBalancerBefore.sub(toBN(recipient.amount))
        );
        // Contract should track remaining rewards.
        expect((await merkleDistributor.merkleWindows(windowIndex)).remainingAmount).to.eq(
          remainingAmountBefore.sub(toBN(recipient.amount))
        );
        // User should be marked as claimed and cannot claim again.
        expect(await merkleDistributor.isClaimed(windowIndex, recipient.accountIndex)).to.be.true;
        // Should fail for same account and window index, even if caller is another account.
        claimTx = merkleDistributor.connect(otherAddress).claim({
          windowIndex,
          account: recipient.account,
          accountIndex: recipient.accountIndex,
          amount: recipient.amount,
          merkleProof: claimerProof,
        });
        await expect(claimTx).to.be.reverted;
      }
    });
  });

  describe("Trivial 2 Leaf Tree", function () {
    describe("(claim)", function () {
      // For each test in the single window, load in the SampleMerklePayouts, generate a tree and set it in the distributor.
      beforeEach(async function () {
        // Window should be the first in the contract.
        windowIndex = 0;

        rewardRecipients = createRewardRecipientsFromSampleData(SamplePayouts);

        // Generate leafs for each recipient. This is simply the hash of each component of the payout from above.
        rewardLeafs = rewardRecipients.map((item) => ({ ...item, leaf: createLeaf(item) }));
        merkleTree = new MerkleTree(rewardLeafs.map((item) => item.leaf));

        // Seed the merkleDistributor with the root of the tree and additional information.
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);

        leaf = rewardLeafs[0];
        claimerProof = merkleTree.getProof(leaf.leaf);
      });
      it("Claim reverts when no rewards to transfer", async function () {
        // First withdraw rewards out of the contract.
        await merkleDistributor
          .connect(contractCreator)
          .withdrawRewards(rewardToken.address, SamplePayouts.totalRewardsDistributed);

        // Claim should fail:
        await expect(
          merkleDistributor.connect(contractCreator).withdrawRewards({
            windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;
      });
      it("Cannot claim for invalid window index", async function () {
        await expect(
          merkleDistributor.connect(contractCreator).claim({
            windowIndex: windowIndex + 1,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;
      });
      it("Can claim on another account's behalf if claimer is whitelisted", async function () {
        const claimerBalanceBefore = toBN(await rewardToken.connect(contractCreator).balanceOf(leaf.account));

        // Temporarily take off whitelist
        await merkleDistributor.connect(contractCreator).whitelistClaimer(otherAddress.address, false);
        await expect(
          merkleDistributor.connect(otherAddress).claim({
            windowIndex: windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;

        await merkleDistributor.connect(contractCreator).whitelistClaimer(otherAddress.address, true);
        const claimTx = await merkleDistributor.connect(otherAddress).claim({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });
        expect((await rewardToken.connect(contractCreator).balanceOf(leaf.account)).toString()).to.equal(
          claimerBalanceBefore.add(toBN(leaf.amount)).toString()
        );
        await expect(claimTx)
          .to.emit(merkleDistributor, "Claimed")
          .withArgs(
            otherAddress.address,
            windowIndex.toString(),
            ethers.utils.getAddress(leaf.account),
            leaf.accountIndex.toString(),
            leaf.amount.toString(),
            rewardToken.address
          );
      });
      it("Whitelisted caller can claim on behalf of beneficiary", async function () {
        const claimerBalanceBefore = toBN(await rewardToken.connect(contractCreator).balanceOf(otherAddress.address));
        expect(otherAddress.address.toLowerCase() !== leaf.account.toLowerCase()).to.be.true;

        // Temporarily take off whitelist
        await merkleDistributor.connect(contractCreator).whitelistClaimer(otherAddress.address, false);
        await expect(
          merkleDistributor.connect(otherAddress).claimFor({
            windowIndex: windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;

        await merkleDistributor.connect(contractCreator).whitelistClaimer(otherAddress.address, true);
        const claimTx = await merkleDistributor.connect(otherAddress).claimFor({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });
        expect((await rewardToken.balanceOf(otherAddress.address)).toString()).to.equal(
          claimerBalanceBefore.add(toBN(leaf.amount)).toString()
        );

        // Can't claim again.
        await expect(
          merkleDistributor.connect(otherAddress).claimFor({
            windowIndex: windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;

        expect((await rewardToken.balanceOf(leaf.account)).toString()).to.equal(toBN(0));
        await expect(claimTx)
          .to.emit(merkleDistributor, "Claimed")
          .withArgs(
            otherAddress.address,
            windowIndex.toString(),
            ethers.utils.getAddress(leaf.account),
            leaf.accountIndex.toString(),
            leaf.amount.toString(),
            rewardToken.address
          );
        const eventFilter = merkleDistributor.filters.ClaimFor;
        const events = await merkleDistributor.queryFilter(eventFilter());
        expect(
          events[0]?.args?.caller.toLowerCase() === otherAddress.address.toLowerCase() &&
            events[0]?.args?.account.toLowerCase() === leaf.account.toLowerCase()
        ).to.be.true;
      });
      it("Cannot double claim rewards", async function () {
        await merkleDistributor.connect(contractCreator).claim({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });
        await expect(
          merkleDistributor.connect(contractCreator).claim({
            windowIndex: windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          })
        ).to.be.reverted;
      });
      it("Claim for one window does not affect other windows", async function () {
        // Create another duplicate Merkle root. `setWindowMerkleRoot` will dynamically
        // increment the index for this new root.
        rewardRecipients = createRewardRecipientsFromSampleData(SamplePayouts);
        const otherRewardLeafs = rewardRecipients.map((item) => ({ ...item, leaf: createLeaf(item) }));
        const otherMerkleTree = new MerkleTree(rewardLeafs.map((item) => item.leaf));
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);

        // Assumption: otherLeaf and leaf are claims for the same account.
        const otherLeaf = otherRewardLeafs[0];
        const otherClaimerProof = otherMerkleTree.getProof(leaf.leaf);
        const startingBalance = toBN(await rewardToken.connect(contractCreator).balanceOf(otherLeaf.account));

        // Create a claim for original tree and show that it does not affect the claim for the same
        // proof for this tree. This effectively tests that the `claimed` mapping correctly
        // tracks claims across window indices.
        await merkleDistributor.connect(contractCreator).claim({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });

        // Can claim for other window index.
        await merkleDistributor.connect(contractCreator).claim({
          windowIndex: windowIndex + 1,
          account: otherLeaf.account,
          accountIndex: otherLeaf.accountIndex,
          amount: otherLeaf.amount,
          merkleProof: otherClaimerProof,
        });

        // Balance should have increased by both claimed amounts:
        expect((await rewardToken.connect(contractCreator).balanceOf(otherLeaf.account)).toString()).to.equal(
          startingBalance.add(toBN(leaf.amount).add(toBN(otherLeaf.amount))).toString()
        );
      });
      it("invalid proof", async function () {
        // Reverts unless `claim` is valid.
        const isInvalidProof = async (claim: any) => {
          // 1) Claim should revert
          // 2) verifyClaim should return false
          await expect(merkleDistributor.connect(contractCreator).claim(claim)).to.be.reverted;
          expect((await merkleDistributor.connect(contractCreator).verifyClaim(claim)) === false).to.eq(true);
        };
        // Incorrect account:
        await isInvalidProof({
          windowIndex: windowIndex,
          account: otherAddress.address,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });
        // Incorrect amount:
        const invalidAmount = "1";
        await isInvalidProof({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: invalidAmount,
          merkleProof: claimerProof,
        });
        // Incorrect account index:
        const invalidAccountIndex = "99";
        await isInvalidProof({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: invalidAccountIndex,
          amount: leaf.amount,
          merkleProof: claimerProof,
        });

        // Invalid merkle proof:
        const invalidProof = [utf8ToHex("0x")];
        await isInvalidProof({
          windowIndex: windowIndex,
          account: leaf.account,
          accountIndex: leaf.accountIndex,
          amount: leaf.amount,
          merkleProof: invalidProof,
        });
      });
      it("Underfunded window", async function () {
        // Fund another rewards window with the same Merkle tree, but insufficient funding.
        const insufficientTotalRewards = toBN(SamplePayouts.totalRewardsDistributed).sub(toBN("1"));
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(insufficientTotalRewards, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);
        const underfundedWindowIndex = windowIndex + 1;

        // Track claimed rewards and change in contract balance for the underfunded rewards window.
        let claimedUnderfundedRewards = toBN("0");
        const contractBalanceBefore = toBN(
          await rewardToken.connect(contractCreator).balanceOf(merkleDistributor.address)
        );
        // Process all claims for the underfunded rewards window.
        for (let i = 0; i < rewardLeafs.length; i++) {
          leaf = rewardLeafs[i];
          claimerProof = merkleTree.getProof(leaf.leaf);
          const claim = {
            windowIndex: underfundedWindowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          };
          // Verify that the claim from underfunded window is valid.
          expect(await merkleDistributor.connect(contractCreator).verifyClaim(claim)).to.be.true;
          const remainingAmount = insufficientTotalRewards.sub(claimedUnderfundedRewards);
          if (remainingAmount.gte(toBN(leaf.amount))) {
            // Claim on underfunded rewards window should succeed as individual claim amount does not
            // yet exceed the `remainingAmount`.
            await merkleDistributor.connect(contractCreator).claim(claim);
            claimedUnderfundedRewards = claimedUnderfundedRewards.add(toBN(leaf.amount));
          } else {
            // `remainingAmount` is less than claim amount thus the claim should fail.
            await expect(merkleDistributor.connect(contractCreator).claim(claim)).to.be.reverted;
          }
        }
        // Verify that tracked successful claimed rewards matches total decrease in contract balance.
        expect((await rewardToken.connect(contractCreator).balanceOf(merkleDistributor.address)).toString()).to.equal(
          contractBalanceBefore.sub(claimedUnderfundedRewards).toString()
        );
        // Verify that total claimed amount does not exceed total rewards for the underfunded reward window.
        expect(claimedUnderfundedRewards.lte(insufficientTotalRewards)).to.be.true;

        // It should be possible to claim all rewards from the original rewards window.
        for (let i = 0; i < rewardLeafs.length; i++) {
          leaf = rewardLeafs[i];
          claimerProof = merkleTree.getProof(leaf.leaf);
          const claim = {
            windowIndex: windowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: claimerProof,
          };
          await merkleDistributor.connect(contractCreator).claim(claim);
        }
      });
    });
    describe("(claimMulti)", function () {
      // 3 Total Trees to test multiple combinations of (1) receiver accounts and (2) reward currencies.
      let rewardRecipients: Recipient[][];
      let rewardLeafs: (Recipient & { leaf: Buffer })[][];
      let merkleTrees: MerkleTree[];
      let alternateRewardToken: Contract;
      let batchedClaims: RecipientWithProof[];
      let lastUsedWindowIndex: number;

      beforeEach(async function () {
        // Reset arrays between tests:
        batchedClaims = [];
        rewardLeafs = [];
        rewardRecipients = [];
        merkleTrees = [];
        lastUsedWindowIndex = 0;

        // First tree reward recipients are same as other tests
        rewardRecipients.push(createRewardRecipientsFromSampleData(SamplePayouts));

        // Second set of reward recipients gets double the rewards of first set. Note:
        // we make reward amounts different so that tester doesn't get a false positive
        // when accidentally re-using proofs between trees. I.e. a claim proof for leaf 1 tree 2
        // should never work for leaf 1 tree 1 or leaf 1 tree 3.
        rewardRecipients.push(
          rewardRecipients[0].map((recipient) => {
            return { ...recipient, amount: toBN(recipient.amount).mul(2).toString() };
          })
        );

        // Third set of reward recipients has double the amount as second, and different currency.
        rewardRecipients.push(
          rewardRecipients[1].map((recipient) => {
            return { ...recipient, amount: toBN(recipient.amount).mul(2).toString() };
          })
        );
        // Generate leafs for each recipient. This is simply the hash of each component of the payout from above.
        rewardRecipients.forEach((_rewardRecipients) => {
          rewardLeafs.push(_rewardRecipients.map((item) => ({ ...item, leaf: createLeaf(item) })));
        });
        rewardLeafs.forEach((_rewardLeafs) => {
          merkleTrees.push(new MerkleTree(_rewardLeafs.map((item) => item.leaf)));
        });
        // Seed the merkleDistributor with the root of the tree and additional information.
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(
            SamplePayouts.totalRewardsDistributed,
            rewardToken.address,
            merkleTrees[0].getRoot(),
            sampleIpfsHash
          );
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(
            String(Number(SamplePayouts.totalRewardsDistributed) * 2),
            rewardToken.address,
            merkleTrees[1].getRoot(),
            sampleIpfsHash
          );
        // Third Merkle tree uses different currency:
        alternateRewardToken = await deployErc20(contractCreator, `Test Token #2`, `T2`);
        await alternateRewardToken.connect(contractCreator).mint(contractCreator.address, MAX_UINT_VAL);
        await alternateRewardToken.connect(contractCreator).approve(merkleDistributor.address, MAX_UINT_VAL);

        await merkleDistributor
          .connect(contractCreator)
          .setWindow(
            String(Number(SamplePayouts.totalRewardsDistributed) * 4),
            alternateRewardToken.address,
            merkleTrees[2].getRoot(),
            sampleIpfsHash
          );
        // Construct claims for all trees assuming that each tree index is equal to its window index.
        for (let i = 0; i < rewardLeafs.length; i++) {
          rewardLeafs[i].forEach((leaf) => {
            batchedClaims.push({
              windowIndex: lastUsedWindowIndex + i,
              account: leaf.account,
              accountIndex: leaf.accountIndex,
              amount: leaf.amount,
              merkleProof: merkleTrees[i].getProof(leaf.leaf),
            });
          });
        }
      });
      it("Can make multiple claims in one transaction", async function () {
        // The same accounts make claims on all three trees, we will track their balances. This allows
        // us to query the recipients from the first window (index 0) to track all of the recipients.
        const allRecipients = rewardRecipients[0];
        const balancesRewardToken = [];
        const balancesAltRewardToken = [];
        for (const recipient of allRecipients) {
          const account = recipient.account;
          balancesRewardToken.push(toBN(await rewardToken.connect(contractCreator).balanceOf(account)));
          balancesAltRewardToken.push(toBN(await alternateRewardToken.connect(contractCreator).balanceOf(account)));
        }

        // Temporarily take off whitelist and show that claimer can't claimMulti a batch including
        // other recipients, unless they are whitelisted
        await merkleDistributor.connect(contractCreator).whitelistClaimer(contractCreator.address, false);
        await expect(merkleDistributor.connect(contractCreator).claimMulti(batchedClaims)).to.be.reverted;
        await merkleDistributor.connect(contractCreator).whitelistClaimer(contractCreator.address, true);

        // Batch claim and check balances.
        await merkleDistributor.connect(contractCreator).claimMulti(batchedClaims);
        for (let i = 0; i < allRecipients.length; i++) {
          // Trees 0 and 1 payout in rewardToken.
          const expectedPayoutRewardToken = toBN(rewardLeafs[0][i].amount).add(toBN(rewardLeafs[1][i].amount));
          // Trees 2 payout in altRewardToken
          const expectedPayoutAltRewardToken = toBN(rewardLeafs[2][i].amount);

          const account = allRecipients[i].account;
          expect(balancesRewardToken[i].add(expectedPayoutRewardToken).toString()).equal(
            (await rewardToken.connect(contractCreator).balanceOf(account)).toString()
          );
          expect(balancesAltRewardToken[i].add(expectedPayoutAltRewardToken).toString()).equal(
            (await alternateRewardToken.connect(contractCreator).balanceOf(account)).toString()
          );
        }

        // One Claimed event should have been emitted for each batched claim.
        const eventFilter = merkleDistributor.filters.Claimed;
        const events = await merkleDistributor.queryFilter(eventFilter());
        expect(events.length).to.equal(allRecipients.length * 3);
      });
      it("Can make multiple claims for one token across multiple windows with single leaf trees", async function () {
        // This tests that claimMulti correctly decrements `remainingAmount` for each merkle window.
        const window1RewardAmount = toBN(toWei("100"));
        const window2RewardAmount = toBN(toWei("300"));

        // Set two windows with trivial one leaf trees.
        const reward1Recipients = [
          {
            account: accounts[3].address,
            amount: window1RewardAmount.toString(),
            accountIndex: 1,
          },
        ];
        const reward2Recipients = [
          {
            account: accounts[3].address,
            amount: window2RewardAmount.toString(),
            accountIndex: 1,
          },
        ];
        const merkleTree1 = new MerkleTree(reward1Recipients.map((item) => createLeaf(item)));
        const nextWindowIndex = (await merkleDistributor.nextCreatedIndex()).toNumber();
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(window1RewardAmount, rewardToken.address, merkleTree1.getRoot(), "");
        const merkleTree2 = new MerkleTree(reward2Recipients.map((item) => createLeaf(item)));
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(window2RewardAmount, rewardToken.address, merkleTree2.getRoot(), "");

        batchedClaims = [
          {
            windowIndex: nextWindowIndex,
            account: reward1Recipients[0].account,
            accountIndex: reward1Recipients[0].accountIndex,
            amount: reward1Recipients[0].amount,
            merkleProof: merkleTree1.getProof(createLeaf(reward1Recipients[0])),
          },
          {
            windowIndex: nextWindowIndex + 1,
            account: reward2Recipients[0].account,
            accountIndex: reward2Recipients[0].accountIndex,
            amount: reward2Recipients[0].amount,
            merkleProof: merkleTree2.getProof(createLeaf(reward2Recipients[0])),
          },
        ];

        await merkleDistributor.claimMulti(batchedClaims);
        // const eventFilter = merkleDistributor.filters.Claimed;
        // const events = await merkleDistributor.queryFilter(eventFilter());
        // expect(events.length).to.equal(batchedClaims.length);
      });
      it("Fails if any individual claim fails", async function () {
        // Push an invalid claim with an incorrect window index.
        batchedClaims.push({
          windowIndex: 9,
          account: rewardLeafs[0][0].account,
          accountIndex: rewardLeafs[0][0].accountIndex,
          amount: rewardLeafs[0][0].amount,
          merkleProof: merkleTrees[0].getProof(rewardLeafs[0][0].leaf),
        });
        await expect(merkleDistributor.connect(contractCreator).claimMulti(batchedClaims)).to.be.reverted;
      });
      it("Underfunded window fails", async function () {
        // Claims will be batched separately for the underfunded reward window.
        const underfundedBatchedClaims: any[] = [];
        const underfundedWindowIndex = rewardLeafs.length;

        // Underfunded rewards set has amounts the same as for the first set, but all recipients are the same one
        // address in order to check if remainingAmount is being tracked correctly.
        const underfundedRewards = Object.keys(SamplePayouts.recipients).map((recipientAddress, i, recipients) => {
          return {
            account: recipients[0],
            amount: (SamplePayouts.recipients as { [key: string]: string })[recipientAddress],
            accountIndex: i,
          };
        });
        rewardRecipients.push(underfundedRewards);

        // Generate leafs for each recipient for the underfunded reward set.
        rewardLeafs.push(rewardRecipients[underfundedWindowIndex].map((item) => ({ ...item, leaf: createLeaf(item) })));
        merkleTrees.push(new MerkleTree(rewardLeafs[underfundedWindowIndex].map((item) => item.leaf)));

        // Fund rewards window with the same Merkle tree, but insufficient funding.
        const insufficientTotalRewards = toBN(SamplePayouts.totalRewardsDistributed).sub(toBN("1"));
        await merkleDistributor
          .connect(contractCreator)
          .setWindow(
            insufficientTotalRewards,
            rewardToken.address,
            merkleTrees[underfundedWindowIndex].getRoot(),
            sampleIpfsHash
          );

        // Construct claims for the underfunded rewards set.
        rewardLeafs[underfundedWindowIndex].forEach((leaf) => {
          underfundedBatchedClaims.push({
            windowIndex: underfundedWindowIndex,
            account: leaf.account,
            accountIndex: leaf.accountIndex,
            amount: leaf.amount,
            merkleProof: merkleTrees[underfundedWindowIndex].getProof(leaf.leaf),
          });
        });

        // Track contract balance for primary reward token.
        const contractBalanceBefore = toBN(
          await rewardToken.connect(contractCreator).balanceOf(merkleDistributor.address)
        );

        // Claiming underfunded rewards should revert and contract balance should remain the same.
        await expect(merkleDistributor.connect(contractCreator).claimMulti(underfundedBatchedClaims)).to.be.reverted;
        expect(contractBalanceBefore.toString()).to.equal(
          await rewardToken.connect(contractCreator).balanceOf(merkleDistributor.address)
        );
      });
    });
  });

  describe("(setWindow)", () => {
    beforeEach(() => {
      rewardRecipients = createRewardRecipientsFromSampleData(SamplePayouts);
      recipientsWithLeafs = rewardRecipients.map((recipient) => ({
        ...recipient,
        leaf: createLeaf(recipient),
      }));
      merkleTree = new MerkleTree(recipientsWithLeafs.map((recipient) => recipient.leaf));
    });

    it("should be called only by owner", async () => {
      await expect(
        merkleDistributor
          .connect(otherAddress)
          .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash)
      ).to.be.reverted;
    });

    it("should transfer owner's balance to contract", async () => {
      const balanceBefore = toBN(await rewardToken.balanceOf(contractCreator.address));
      const expectedBalanceAfter = balanceBefore.sub(toBN(SamplePayouts.totalRewardsDistributed)).toString();

      await merkleDistributor
        .connect(contractCreator)
        .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);
      const balanceAfter = (await rewardToken.balanceOf(contractCreator.address)).toString();
      expect(expectedBalanceAfter).to.eq(balanceAfter);
    });

    it("(nextCreatedIndex): starts at 0 and increments on each seed", async () => {
      expect((await merkleDistributor.nextCreatedIndex()).toString()).to.eq("0");
      await merkleDistributor
        .connect(contractCreator)
        .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);
      expect((await merkleDistributor.nextCreatedIndex()).toString()).to.eq("1");
    });

    it("should store reward amount", async () => {
      await merkleDistributor
        .connect(contractCreator)
        .setWindow(SamplePayouts.totalRewardsDistributed, rewardToken.address, merkleTree.getRoot(), sampleIpfsHash);
      const contractAmount = (await merkleDistributor.merkleWindows(0)).remainingAmount.toString();
      expect(contractAmount).to.eq(SamplePayouts.totalRewardsDistributed);
    });
  });
});
