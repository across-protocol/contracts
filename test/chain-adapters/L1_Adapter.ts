import * as consts from "../constants";
import { ethers, expect, Contract, SignerWithAddress, randomAddress } from "../utils";
import { getContractFactory, seedWallet } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";

let hubPool: Contract, l1Adapter: Contract, weth: Contract, dai: Contract, mockSpoke: Contract, timer: Contract;
let owner: SignerWithAddress,
  dataWorker: SignerWithAddress,
  liquidityProvider: SignerWithAddress,
  crossChainAdmin: SignerWithAddress;

const l1ChainId = 1;

describe("L1 Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, dai, hubPool, mockSpoke, timer, crossChainAdmin } = await hubPoolFixture());
    await seedWallet(dataWorker, [dai], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [dai], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, dai]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    await dai.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(dai.address, consts.amountToLp);
    await dai.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));

    l1Adapter = await (await getContractFactory("L1_Adapter", owner)).deploy(hubPool.address);

    await hubPool.setCrossChainContracts(l1ChainId, l1Adapter.address, mockSpoke.address);

    await hubPool.whitelistRoute(l1ChainId, l1ChainId, weth.address, weth.address);

    await hubPool.whitelistRoute(l1ChainId, l1ChainId, dai.address, dai.address);
  });

  it("relayMessage calls spoke pool functions", async function () {
    expect(await mockSpoke.crossDomainAdmin()).to.equal(crossChainAdmin.address);
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(l1ChainId, functionCallData))
      .to.emit(l1Adapter, "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData);

    expect(await mockSpoke.crossDomainAdmin()).to.equal(newAdmin);
  });
  it("Correctly transfers tokens when executing pool rebalance", async function () {
    const { leafs, tree, tokensSendToL2 } = await constructSingleChainTree(dai.address, 1, l1ChainId);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle(
        [3117],
        1,
        tree.getHexRoot(),
        consts.mockRelayerRefundRoot,
        consts.mockSlowRelayFulfillmentRoot
      );
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness);
    expect(await hubPool.connect(dataWorker).executeRootBundle(leafs[0], tree.getHexProof(leafs[0])))
      .to.emit(l1Adapter, "TokensRelayed")
      .withArgs(dai.address, dai.address, tokensSendToL2, mockSpoke.address);
  });
});
