import { mockTreeRoot, amountToReturn, amountHeldByPool, TokenRolesEnum } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedContract,
  toWei,
  toWeiWithDecimals,
  BigNumber,
  randomBytes32,
  createTypedFakeFromABI,
  getHyperlaneDomainId,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";
import { IHypXERC20Router__factory } from "../../../../typechain";
import { CHAIN_IDs } from "@across-protocol/constants";

let hubPool: Contract, lineaSpokePool: Contract, dai: Contract, weth: Contract, usdc: Contract, l2EzETH: Contract;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let lineaMessageService: FakeContract,
  lineaTokenBridge: FakeContract,
  lineaUsdcBridge: FakeContract,
  l2HypXERC20Router: FakeContract;

const hyperlaneDstDomain = getHyperlaneDomainId(CHAIN_IDs.MAINNET);

const lineaMessageServiceAbi = [
  {
    inputs: [
      { internalType: "address", name: "_to", type: "address" },
      { internalType: "uint256", name: "_fee", type: "uint256" },
      { internalType: "bytes", name: "_calldata", type: "bytes" },
    ],
    name: "sendMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "sender",
    outputs: [
      {
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
  {
    inputs: [],
    name: "minimumFeeInWei",
    outputs: [
      {
        name: "",
        type: "uint256",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

const lineaTokenBridgeAbi = [
  {
    inputs: [
      { internalType: "address", name: "_token", type: "address" },
      { internalType: "uint256", name: "_amount", type: "uint256" },
      { internalType: "address", name: "_recipient", type: "address" },
    ],
    name: "bridgeToken",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

const lineaUsdcBridgeAbi = [
  {
    inputs: [
      { internalType: "uint256", name: "amount", type: "uint256" },
      { internalType: "address", name: "to", type: "address" },
    ],
    name: "depositTo",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [],
    name: "usdc",
    outputs: [
      {
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

describe("Linea Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, usdc, hubPool } = await hubPoolFixture());

    // create ezETH token for XERC20 testing
    l2EzETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await l2EzETH.addMember(TokenRolesEnum.MINTER, owner.address);

    lineaMessageService = await smock.fake(lineaMessageServiceAbi, {
      address: "0x508Ca82Df566dCD1B0DE8296e70a96332cD644ec",
    });
    lineaMessageService.minimumFeeInWei.returns(0);
    lineaMessageService.sender.reset();
    lineaTokenBridge = await smock.fake(lineaTokenBridgeAbi, { address: "0x353012dc4a9A6cF55c941bADC267f82004A8ceB9" });
    lineaUsdcBridge = await smock.fake(lineaUsdcBridgeAbi, {
      address: "0xA2Ee6Fce4ACB62D95448729cDb781e3BEb62504A",
    });
    lineaUsdcBridge.usdc.returns(usdc.address);
    l2HypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);

    await owner.sendTransaction({ to: lineaMessageService.address, value: toWei("1") });

    lineaSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Linea_SpokePool", owner),
      [
        0,
        lineaMessageService.address,
        lineaTokenBridge.address,
        lineaUsdcBridge.address,
        owner.address,
        hubPool.address,
      ],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, hyperlaneDstDomain, toWei("1")],
      }
    );

    await seedContract(lineaSpokePool, relayer, [dai, usdc, l2EzETH], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    const implementation = await hre.upgrades.deployImplementation(await getContractFactory("Linea_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, hyperlaneDstDomain, toWei("1")],
    });

    // upgradeTo fails unless called by cross domain admin
    await expect(lineaSpokePool.connect(lineaMessageService.wallet).upgradeTo(implementation)).to.be.revertedWith(
      "ONLY_COUNTERPART_GATEWAY"
    );
    lineaMessageService.sender.returns(owner.address);
    // msg.sender must be lineaMessageService
    await expect(lineaSpokePool.connect(owner).upgradeTo(implementation)).to.be.revertedWith(
      "ONLY_COUNTERPART_GATEWAY"
    );
    await lineaSpokePool.connect(lineaMessageService.wallet).upgradeTo(implementation);
  });
  it("Only cross domain owner can set l2MessageService", async function () {
    await expect(lineaSpokePool.setL2MessageService(lineaMessageService.wallet)).to.be.reverted;
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).setL2MessageService(rando.address);
    expect(await lineaSpokePool.l2MessageService()).to.equal(rando.address);
  });
  it("Only cross domain owner can set l2TokenBridge", async function () {
    await expect(lineaSpokePool.setL2TokenBridge(lineaMessageService.wallet)).to.be.reverted;
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).setL2TokenBridge(rando.address);
    expect(await lineaSpokePool.l2TokenBridge()).to.equal(rando.address);
  });
  it("Only cross domain owner can set l2UsdcBridge", async function () {
    await expect(lineaSpokePool.setL2UsdcBridge(lineaMessageService.wallet)).to.be.reverted;
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).setL2UsdcBridge(rando.address);
    expect(await lineaSpokePool.l2UsdcBridge()).to.equal(rando.address);
  });
  it("Only cross domain owner can relay admin root bundles", async function () {
    const { tree } = await constructSingleRelayerRefundTree(dai.address, await lineaSpokePool.callStatic.chainId());
    await expect(lineaSpokePool.relayRootBundle(tree.getHexRoot(), mockTreeRoot)).to.be.revertedWith(
      "ONLY_COUNTERPART_GATEWAY"
    );
  });
  it("Anti-DDoS message fee needs to be set", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await lineaSpokePool.callStatic.chainId()
    );
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    lineaMessageService.sender.reset();
    lineaMessageService.minimumFeeInWei.returns(1);
    await expect(
      lineaSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.be.revertedWith("MESSAGE_FEE_MISMATCH");
  });
  it("Bridge tokens to hub pool correctly calls the L2 Token Bridge for ERC20", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await lineaSpokePool.callStatic.chainId()
    );
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    // Simulate if the fee is positive to ensure that the contract unwraps enough ETH to cover the fee.
    const fee = toWei("0.01");
    lineaMessageService.minimumFeeInWei.returns(fee);
    await lineaSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: fee });
    // Ensure that linea message service is paid the fee by the LineaSpokePool contract to send an L2 to L1 message.
    expect(lineaTokenBridge.bridgeToken).to.have.been.calledWithValue(fee);

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(lineaTokenBridge.bridgeToken).to.have.been.calledWith(dai.address, amountToReturn, hubPool.address);
  });
  it("Bridge USDC to hub pool correctly calls the L2 USDC Bridge", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      usdc.address,
      await lineaSpokePool.callStatic.chainId()
    );
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    const fee = toWei("0.01");
    lineaMessageService.minimumFeeInWei.returns(fee);
    await lineaSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: fee });

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(lineaUsdcBridge.depositTo).to.have.been.calledWith(amountToReturn, hubPool.address);
    expect(lineaUsdcBridge.depositTo).to.have.been.calledWithValue(fee);
  });
  it("Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH, including unwrap", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      weth.address,
      await lineaSpokePool.callStatic.chainId()
    );
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    const fee = toWei("0.01");
    lineaMessageService.minimumFeeInWei.returns(fee);

    // Executing the refund leaf should cause spoke pool to unwrap WETH to ETH to prepare to send it as msg.value
    // to the ERC20 bridge. This results in a net decrease in WETH balance.
    await expect(() =>
      lineaSpokePool
        .connect(relayer)
        .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: fee })
    ).to.changeTokenBalance(weth, lineaSpokePool, amountToReturn.mul(-1));
    expect(lineaMessageService.sendMessage).to.have.been.calledWith(hubPool.address, fee, "0x");
    expect(lineaMessageService.sendMessage).to.have.been.calledWithValue(amountToReturn.add(fee));
  });
  it("Bridge tokens to hub pool correctly using the Hyperlane XERC20 messaging for ezETH token", async function () {
    // Set up XERC20 router for l2EzETH
    lineaMessageService.sender.returns(owner.address);
    l2HypXERC20Router.wrappedToken.returns(l2EzETH.address);
    await lineaSpokePool
      .connect(lineaMessageService.wallet)
      .setHypXERC20Router(l2EzETH.address, l2HypXERC20Router.address);
    lineaMessageService.sender.reset();

    const hypXERC20Fee = toWeiWithDecimals("1", 9).mul(200_000); // 1 GWEI gas price * 200,000 gas cost
    l2HypXERC20Router.quoteGasPayment.returns(hypXERC20Fee);

    const ezETHSendAmount = BigNumber.from("1234567000000000000");
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2EzETH.address,
      await lineaSpokePool.callStatic.chainId(),
      ezETHSendAmount
    );
    lineaMessageService.sender.returns(owner.address);
    await lineaSpokePool.connect(lineaMessageService.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    await lineaSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: hypXERC20Fee.add(hypXERC20Fee) });

    // Adapter should have approved l2HypXERC20Router to spend its ERC20
    expect(await l2EzETH.allowance(lineaSpokePool.address, l2HypXERC20Router.address)).to.equal(ezETHSendAmount);

    expect(l2HypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledWith(
      hyperlaneDstDomain,
      ethers.utils.hexZeroPad(hubPool.address, 32).toLowerCase(),
      ezETHSendAmount
    );
  });
});
