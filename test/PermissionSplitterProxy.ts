import {
  getContractFactory,
  SignerWithAddress,
  seedWallet,
  expect,
  Contract,
  ethers,
  randomAddress,
  utf8ToHex,
} from "../utils/utils";
import {
  originChainId,
  destinationChainId,
  bondAmount,
  zeroAddress,
  mockTreeRoot,
  mockSlowRelayRoot,
  finalFeeUsdc,
  finalFee,
  totalBond,
} from "./constants";
import { hubPoolFixture } from "./fixtures/HubPool.Fixture";

let hubPool: Contract, weth: Contract, usdc: Contract, permissionSplitter: Contract, hubPoolProxy: Contract;
let mockSpoke: Contract, mockAdapter: Contract, identifierWhitelist: Contract;
let owner: SignerWithAddress, other: SignerWithAddress, delegate: SignerWithAddress;
let delegateRole: string, defaultAdminRole: string;

const enableTokenSelector = "0xb60c2d7d";

describe("PermissionSplitterProxy", function () {
  beforeEach(async function () {
    [owner, delegate, other] = await ethers.getSigners();
    ({ weth, hubPool, usdc, mockAdapter, mockSpoke, identifierWhitelist } = await hubPoolFixture());
    const permissionSplitterFactory = await getContractFactory("PermissionSplitterProxy", owner);
    const hubPoolFactory = await getContractFactory("HubPool", owner);

    permissionSplitter = await permissionSplitterFactory.deploy(hubPool.address);
    hubPoolProxy = hubPoolFactory.attach(permissionSplitter.address);
    delegateRole = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("DELEGATE_ROLE"));
    permissionSplitter.connect(owner).grantRole(delegateRole, delegate.address);
    defaultAdminRole = ethers.utils.hexZeroPad("0x00", 32);
    await hubPool.transferOwnership(permissionSplitter.address);
  });

  it("Cannot run method until whitelisted", async function () {
    await expect(hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
    await permissionSplitter.connect(owner).__setRoleForSelector(enableTokenSelector, delegateRole);
    await hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(true);
  });
  it("Owner can run without whitelisting", async function () {
    await hubPoolProxy.connect(owner).enableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(true);
  });

  it("Owner can revoke role", async function () {
    await expect(hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
    await permissionSplitter.connect(owner).__setRoleForSelector(enableTokenSelector, delegateRole);
    await hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(true);

    await permissionSplitter.connect(owner).revokeRole(delegateRole, delegate.address);
    await expect(hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(usdc.address)).to.be.reverted;
  });

  it("Owner can revoke selector", async function () {
    await expect(hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address)).to.be.reverted;
    await permissionSplitter.connect(owner).__setRoleForSelector(enableTokenSelector, delegateRole);
    await hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(weth.address);
    expect((await hubPool.callStatic.pooledTokens(weth.address)).isEnabled).to.equal(true);

    await permissionSplitter.connect(owner).__setRoleForSelector(enableTokenSelector, defaultAdminRole);
    await expect(hubPoolProxy.connect(delegate).enableL1TokenForLiquidityProvision(usdc.address)).to.be.reverted;
  });
});
