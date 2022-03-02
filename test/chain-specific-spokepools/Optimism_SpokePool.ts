import { mockTreeRoot, amountToReturn, amountToRelay, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress, createFake, toWei } from "../utils";
import { getContractFactory, seedContract, avmL1ToL2Alias, hre, toBN, toBNWei } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { buildRelayerRefundTree, buildRelayerRefundLeafs } from "../MerkleLib.utils";

let hubPool: Contract, optimismSpokePool: Contract, merkleLib: Contract, timer: Contract, dai: Contract, weth: Contract;
let l2Weth: string, l2Dai: string, crossDomainMessengerAddress;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;

let crossDomainMessenger: FakeContract;

async function constructSimpleTree(l2Token: Contract | string, destinationChainId: number) {
  const leafs = buildRelayerRefundLeafs(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]] // refundAmounts.
  );

  const tree = await buildRelayerRefundTree(leafs);

  return { leafs, tree };
}
describe.only("Arbitrum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, timer } = await hubPoolFixture());

    // Create the fake at the optimism cross domain messenger pre-deployment address.
    crossDomainMessenger = await createFake("L2CrossDomainMessenger", "0x4200000000000000000000000000000000000007");
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: toWei("1") });

    optimismSpokePool = await (
      await getContractFactory("Optimism_SpokePool", { signer: owner })
    ).deploy(owner.address, hubPool.address, timer.address);

    await seedContract(optimismSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner can set l1GasLimit", async function () {
    crossDomainMessenger.xDomainMessageSender.returns(rando.address);
    await expect(optimismSpokePool.setL1GasLimit(1337)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setL1GasLimit(1337);
    expect(await optimismSpokePool.l1Gas()).to.equal(1337);
  });

  it("Bridge tokens to hub pool correctly calls the Standard L2 Gateway router", async function () {
    // const { leafs, tree } = await constructSimpleTree(l2Dai, await optimismSpokePool.callStatic.chainId());
    // await optimismSpokePool.connect(crossDomainMessenger).initializeRelayerRefund(tree.getHexRoot(), mockTreeRoot);
    // await optimismSpokePool.connect(relayer).distributeRelayerRefund(0, leafs[0], tree.getHexProof(leafs[0]));
    // // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    // // outboundTransfer is overloaded in the arbitrum gateway. Define the interface to check the method is called.
    // const functionKey = "outboundTransfer(address,address,uint256,bytes)";
    // expect(crossDomainMessenger[functionKey]).to.have.been.calledOnce;
    // expect(crossDomainMessenger[functionKey]).to.have.been.calledWith(
    //   dai.address,
    //   hubPool.address,
    //   amountToReturn,
    //   "0x"
    // );
  });
});
