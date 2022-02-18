import { mockTreeRoot, amountToReturn, amountToRelay, amountHeldByPool } from "../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress, createFake, toWei } from "../utils";
import { getContractFactory, seedContract, avmL1ToL2Alias, hre, toBN, toBNWei } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { buildDestinationDistributionLeafTree, buildDestinationDistributionLeafs } from "../MerkleLib.utils";

let hubPool: Contract, optimismSpokePool: Contract, merkleLib: Contract, timer: Contract, dai: Contract, weth: Contract;
let l2Weth: string, l2Dai: string, crossDomainMessengerAddress;

let owner: SignerWithAddress,
  relayer: SignerWithAddress,
  rando: SignerWithAddress,
  crossDomainMessengerPreDeploy: SignerWithAddress;

let crossDomainMessenger: FakeContract;

async function constructSimpleTree(l2Token: Contract | string, destinationChainId: number) {
  const leafs = buildDestinationDistributionLeafs(
    [destinationChainId], // Destination chain ID.
    [amountToReturn], // amountToReturn.
    [l2Token as string], // l2Token.
    [[]], // refundAddresses.
    [[]] // refundAmounts.
  );

  const tree = await buildDestinationDistributionLeafTree(leafs);

  return { leafs, tree };
}
describe.only("Arbitrum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, l2Weth, dai, l2Dai, hubPool, merkleLib, timer } = await hubPoolFixture());

    // Create an alias for the Owner. Impersonate the account. Crate a signer for it and send it ETH.
    crossDomainMessengerAddress = "0x4200000000000000000000000000000000000007";
    // await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [crossDomainMessengerAddress] });
    // crossDomainMessengerPreDeploy = await ethers.getSigner(crossDomainMessengerAddress);
    await owner.sendTransaction({ to: crossDomainMessengerAddress, value: toWei("1") });

    crossDomainMessenger = await createFake("L2CrossDomainMessenger", crossDomainMessengerAddress);

    optimismSpokePool = await (
      await getContractFactory("Optimism_SpokePool", { signer: owner, libraries: { MerkleLib: merkleLib.address } })
    ).deploy(owner.address, hubPool.address, l2Weth, timer.address);

    await seedContract(optimismSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner can set l1GasLimit", async function () {
    crossDomainMessenger.xDomainMessageSender.returns(rando.address);
    await expect(optimismSpokePool.setL1GasLimit(1337)).to.be.reverted;
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    console.log("A", crossDomainMessenger.wallet);
    await optimismSpokePool.connect(crossDomainMessenger.wallet).setL1GasLimit(1337);
    // await optimismSpokePool.connect(crossDomainMessengerPreDeploy).setL1GasLimit(1337);
    console.log("B");
    expect(await optimismSpokePool.crossDomainMessenger()).to.equal(rando.address);
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
