import { mockTreeRoot, amountToReturn, amountHeldByPool, zeroAddress, TokenRolesEnum } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  toWei,
  getContractFactory,
  seedContract,
  createFakeFromABI,
  addressToBytes,
  createTypedFakeFromABI,
  BigNumber,
  toWeiWithDecimals,
} from "../../../../utils/utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { IHypXERC20Router__factory } from "../../../../typechain";

let hubPool: Contract, modeSpokePool: Contract, dai: Contract, weth: Contract, l2EzETH: Contract;
let l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let crossDomainMessenger: FakeContract,
  l2StandardBridge: FakeContract,
  l2CctpTokenMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  l2HypXERC20Router: FakeContract;

const l2Eth = "0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000";

describe("Mode Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, l2Usdc } = await hubPoolFixture());

    // Create ezETH token for XERC20 testing
    l2EzETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await l2EzETH.addMember(TokenRolesEnum.MINTER, owner.address);

    // Create the fake at the Mode cross domain messenger and l2StandardBridge pre-deployment addresses.
    // Mode uses the same addresses as Optimism for these contracts
    crossDomainMessenger = await createFake("L2CrossDomainMessenger", "0x4200000000000000000000000000000000000007");
    l2StandardBridge = await createFake("MockBedrockL2StandardBridge", "0x4200000000000000000000000000000000000010");
    l2CctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    l2CctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));
    l2HypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);

    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: toWei("1") });

    // Deploy Mode_SpokePool instead of using a mock
    modeSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Mode_SpokePool", owner),
      [0, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address],
      }
    );

    await seedContract(modeSpokePool, relayer, [dai, l2EzETH], weth, amountHeldByPool);

    // Set up XERC20 router for l2EzETH
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await modeSpokePool
      .connect(crossDomainMessenger.wallet)
      .setXERC20HypRouter(l2EzETH.address, l2HypXERC20Router.address);
    crossDomainMessenger.xDomainMessageSender.reset();
  });

  it("Bridge tokens to hub pool correctly using the Hyperlane XERC20 messaging for ezETH token", async function () {
    const hypXERC20Fee = toWeiWithDecimals("1", 9).mul(200_000); // 1 GWEI gas price * 200,000 gas cost
    l2HypXERC20Router.quoteGasPayment.returns(hypXERC20Fee);

    const ezETHSendAmount = BigNumber.from("1234567000000000000");
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2EzETH.address,
      await modeSpokePool.callStatic.chainId(),
      ezETHSendAmount
    );

    // Set up admin permission to relay root bundle
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await modeSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    crossDomainMessenger.xDomainMessageSender.reset();

    await modeSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: hypXERC20Fee });

    // Adapter should have approved l2HypXERC20Router to spend its ERC20
    expect(await l2EzETH.allowance(modeSpokePool.address, l2HypXERC20Router.address)).to.equal(ezETHSendAmount);

    const hubPoolHypDomainId = 1;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledWith(
      hubPoolHypDomainId,
      ethers.utils.hexZeroPad(hubPool.address, 32).toLowerCase(),
      ezETHSendAmount
    );
  });
});
