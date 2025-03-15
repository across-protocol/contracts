/* eslint-disable no-unused-expressions */
import * as consts from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  toWei,
  toBN,
  getContractFactory,
  seedWallet,
  randomAddress,
  createTypedFakeFromABI,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import { AdapterStore__factory, IHypXERC20Router__factory } from "../../../../typechain";

describe("Blast_Adapter", function () {
  let hubPool: Contract;
  let blastAdapter: Contract;
  let weth: Contract;
  let dai: Contract;
  let ezETH: Contract;
  let timer: Contract;
  let mockSpoke: Contract;
  let owner: SignerWithAddress;
  let dataWorker: SignerWithAddress;
  let liquidityProvider: SignerWithAddress;
  let l1CrossDomainMessenger: FakeContract;
  let l1StandardBridge: FakeContract;
  let l1BlastBridge: FakeContract;
  let hypXERC20Router: FakeContract;
  let adapterStore: FakeContract;

  // Use Blast chain ID from Hyperlane
  const blastChainId = 81457;
  // Gas limit for L2 execution
  const l2GasLimit = 200000;

  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    const fixture = await hubPoolFixture();
    weth = fixture.weth;
    dai = fixture.dai;
    hubPool = fixture.hubPool;
    mockSpoke = fixture.mockSpoke;
    timer = fixture.timer;

    // Create ezETH token for XERC20 testing
    ezETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await ezETH.addMember(consts.TokenRolesEnum.MINTER, owner.address);
    const l2EzETH = randomAddress();

    // Seed wallets with tokens
    await seedWallet(dataWorker, [ezETH], weth, consts.amountToLp);
    await seedWallet(liquidityProvider, [ezETH], weth, consts.amountToLp.mul(10));

    // Enable tokens for liquidity provision
    await enableTokensForLP(owner, hubPool, weth, [weth, ezETH]);

    // Add liquidity for all tokens
    for (const token of [weth, ezETH]) {
      await token.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
      await hubPool.connect(liquidityProvider).addLiquidity(token.address, consts.amountToLp);
      await token.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
    }

    // Create fake contracts
    adapterStore = await createTypedFakeFromABI([...AdapterStore__factory.abi]);
    hypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);
    l1StandardBridge = await createFake("L1StandardBridge");
    l1CrossDomainMessenger = await createFake("L1CrossDomainMessenger");
    l1BlastBridge = await createFake("IL1ERC20Bridge");

    const hypXERC20FeeCap = toWei("1");

    // Deploy Blast adapter
    blastAdapter = await (
      await getContractFactory("Blast_Adapter", owner)
    ).deploy(
      weth.address,
      l1CrossDomainMessenger.address,
      l1StandardBridge.address,
      fixture.usdc.address,
      l1BlastBridge.address,
      dai.address,
      l2GasLimit,
      blastChainId,
      adapterStore.address,
      hypXERC20FeeCap
    );

    // Seed the HubPool with ETH for L2 calls
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });

    // Set up cross-chain contracts and routes
    await hubPool.setCrossChainContracts(blastChainId, blastAdapter.address, mockSpoke.address);
    await hubPool.setPoolRebalanceRoute(blastChainId, ezETH.address, l2EzETH);
  });

  it("Correctly calls Hyperlane XERC20 bridge", async function () {
    // Set hyperlane router in adapter store
    hypXERC20Router.wrappedToken.returns(ezETH.address);
    await adapterStore.connect(owner).setHypXERC20Router(blastChainId, ezETH.address, hypXERC20Router.address);
    adapterStore.hypXERC20Routers.whenCalledWith(blastChainId, ezETH.address).returns(hypXERC20Router.address);

    // Set up gas payment quote
    hypXERC20Router.quoteGasPayment.returns(toBN(1e9).mul(200_000));

    // Construct repayment bundle
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(ezETH.address, 1, blastChainId);

    // Propose and execute root bundle
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), consts.mockRelayerRefundRoot, consts.mockSlowRelayRoot);

    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + consts.refundProposalLiveness + 1);

    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved gateway to spend its ERC20
    expect(await ezETH.allowance(hubPool.address, hypXERC20Router.address)).to.equal(tokensSendToL2);

    // Blast's domain ID for Hyperlane
    const blastDstDomainId = 81457;

    // We should have called quoteGasPayment on the hypXERC20Router once with correct params
    expect(hypXERC20Router.quoteGasPayment).to.have.been.calledOnce;
    expect(hypXERC20Router.quoteGasPayment).to.have.been.calledWith(blastDstDomainId);

    // We should have called transferRemote on the hypXERC20Router once with correct params
    expect(hypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(hypXERC20Router.transferRemote).to.have.been.calledWith(
      blastDstDomainId,
      ethers.utils.hexZeroPad(mockSpoke.address, 32).toLowerCase(),
      tokensSendToL2
    );
  });
});
