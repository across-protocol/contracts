import { SignerWithAddress, seedContract, seedWallet, expect, Contract, ethers, toBN } from "../../../utils/utils";
import * as consts from "./constants";
import { spokePoolFixture } from "./fixtures/SpokePool.Fixture";

let spokePool: Contract, erc20: Contract, weth: Contract;
let deployerWallet: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let destinationChainId: number;

describe("SpokePool with Blacklisted ERC20", function () {
  beforeEach(async function () {
    [deployerWallet, relayer, rando] = await ethers.getSigners();
    ({ spokePool, erc20, weth } = await spokePoolFixture());

    destinationChainId = Number(await spokePool.chainId());
    await seedContract(spokePool, deployerWallet, [erc20], weth, consts.amountHeldByPool);
  });

  it("Blacklist ERC20 operates as expected", async function () {
    // Transfer tokens to relayer before blacklisting works as expected.
    await seedWallet(deployerWallet, [erc20], weth, consts.amountToRelay);
    await erc20.connect(deployerWallet).transfer(relayer.address, consts.amountToRelay);
    expect(await erc20.balanceOf(relayer.address)).to.equal(consts.amountToRelay);

    await erc20.setBlacklistStatus(relayer.address, true); // Blacklist the relayer

    // Attempt to transfer tokens to the blacklisted relayer
    await expect(erc20.connect(deployerWallet).transfer(relayer.address, consts.amountToRelay)).to.be.revertedWith(
      "Recipient is blacklisted"
    );
  });

  it("Executes repayments and handles blacklisted addresses", async function () {
    // No starting relayer liability.
    expect(await spokePool.getRelayerRefund(erc20.address, relayer.address)).to.equal(toBN(0));
    expect(await erc20.balanceOf(rando.address)).to.equal(toBN(0));
    expect(await erc20.balanceOf(relayer.address)).to.equal(toBN(0));
    // Blacklist the relayer
    await erc20.setBlacklistStatus(relayer.address, true);

    // Distribute relayer refunds. some refunds go to blacklisted address and some go to non-blacklisted address.

    await spokePool
      .connect(deployerWallet)
      .distributeRelayerRefunds(
        destinationChainId,
        consts.amountToReturn,
        [consts.amountToRelay, consts.amountToRelay],
        0,
        erc20.address,
        [relayer.address, rando.address]
      );

    // Ensure relayerRepaymentLiability is incremented
    expect(await spokePool.getRelayerRefund(erc20.address, relayer.address)).to.equal(consts.amountToRelay);
    expect(await erc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);
    expect(await erc20.balanceOf(relayer.address)).to.equal(toBN(0));
  });
  it("Relayer with failed repayment can claim their refund", async function () {
    await erc20.setBlacklistStatus(relayer.address, true);

    await spokePool
      .connect(deployerWallet)
      .distributeRelayerRefunds(destinationChainId, consts.amountToReturn, [consts.amountToRelay], 0, erc20.address, [
        relayer.address,
      ]);

    await expect(spokePool.connect(relayer).claimRelayerRefund(erc20.address, relayer.address)).to.be.revertedWith(
      "Recipient is blacklisted"
    );

    expect(await erc20.balanceOf(rando.address)).to.equal(toBN(0));
    await spokePool.connect(relayer).claimRelayerRefund(erc20.address, rando.address);
    expect(await erc20.balanceOf(rando.address)).to.equal(consts.amountToRelay);
  });
});
