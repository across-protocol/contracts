import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  toWei,
  getContractFactory,
  randomAddress,
  seedContract,
  avmL1ToL2Alias,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";

// TODO: Grab the following from relayer/CONTRACT_ADDRESSES dictionary?
const ERC20_BRIDGE = "0x11f943b2c77b743ab90f4a0ae7d5a4e7fca3e102";
const USDC_BRIDGE = "0x350ACF3d84A6E668E53d4AA682989DCA15Ea27E2";

const abiData = {
  erc20DefaultBridge: {
    abi: [
      {
        inputs: [
          { internalType: "address", name: "_l1Receiver", type: "address" },
          { internalType: "address", name: "_l2Token", type: "address" },
          { internalType: "uint256", name: "_amount", type: "uint256" },
        ],
        name: "withdraw",
        outputs: [],
        payable: false,
        stateMutability: "nonpayable",
        type: "function",
      },
    ],
  },
  eth: {
    address: "0x000000000000000000000000000000000000800A",
    abi: [
      {
        inputs: [{ internalType: "address", name: "_l1Receiver", type: "address" }],
        name: "withdraw",
        outputs: [],
        payable: true,
        stateMutability: "payable",
        type: "function",
      },
    ],
  },
};

describe("ZkSync Spoke Pool", function () {
  const { AddressZero: ZERO_ADDRESS } = ethers.constants;
  const cctpTokenMessenger = ZERO_ADDRESS; // Not currently supported.

  let hubPool: Contract, zkSyncSpokePool: Contract, dai: Contract, usdc: Contract, weth: Contract;
  let l2Dai: string, crossDomainAliasAddress, crossDomainAlias: SignerWithAddress;
  let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
  let zkErc20Bridge: FakeContract, zkUSDCBridge: FakeContract, l2Eth: FakeContract;
  let constructorArgs: unknown[];

  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, usdc, l2Dai, hubPool } = await hubPoolFixture());

    // Create an alias for the Owner. Impersonate the account. Crate a signer for it and send it ETH.
    crossDomainAliasAddress = avmL1ToL2Alias(owner.address); // @dev Uses same aliasing algorithm as Arbitrum
    await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [crossDomainAliasAddress] });
    crossDomainAlias = await ethers.getSigner(crossDomainAliasAddress);
    await owner.sendTransaction({ to: crossDomainAliasAddress, value: toWei("1") });

    zkErc20Bridge = await smock.fake(abiData.erc20DefaultBridge.abi, { address: ERC20_BRIDGE });
    zkUSDCBridge = await smock.fake(abiData.erc20DefaultBridge.abi, { address: USDC_BRIDGE });
    l2Eth = await smock.fake(abiData.eth.abi, { address: abiData.eth.address });
    constructorArgs = [weth.address, usdc.address, zkUSDCBridge.address, cctpTokenMessenger, 60 * 60, 9 * 60 * 60];

    zkSyncSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("ZkSync_SpokePool", owner),
      [0, zkErc20Bridge.address, owner.address, hubPool.address],
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs }
    );

    await seedContract(zkSyncSpokePool, relayer, [dai, usdc], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("ZkSync_SpokePool", owner),
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs }
    );

    // upgradeTo fails unless called by cross domain admin
    await expect(zkSyncSpokePool.upgradeTo(implementation)).to.be.revertedWith("ONLY_COUNTERPART_GATEWAY");
    await zkSyncSpokePool.connect(crossDomainAlias).upgradeTo(implementation);
  });
  it("Only cross domain owner can set ZKBridge", async function () {
    await expect(zkSyncSpokePool.setZkBridge(rando.address)).to.be.reverted;
    await zkSyncSpokePool.connect(crossDomainAlias).setZkBridge(rando.address);
    expect(await zkSyncSpokePool.zkErc20Bridge()).to.equal(rando.address);
  });
  it("Invalid USDC bridge configuration is rejected", async function () {
    let _constructorArgs = [...constructorArgs];
    expect(_constructorArgs[1]).to.equal(usdc.address);
    expect(_constructorArgs[2]).to.equal(zkUSDCBridge.address);
    expect(_constructorArgs[3]).to.equal(cctpTokenMessenger);

    // Verify successful deployment.
    let implementation = hre.upgrades.deployImplementation(await getContractFactory("ZkSync_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: _constructorArgs,
    });
    await expect(implementation).to.not.be.reverted;

    // Configure cctp
    _constructorArgs = [...constructorArgs];
    _constructorArgs[2] = ZERO_ADDRESS;
    _constructorArgs[3] = randomAddress();
    implementation = hre.upgrades.deployImplementation(await getContractFactory("ZkSync_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: _constructorArgs,
    });
    await expect(implementation).to.not.be.reverted;

    // Configure bridged USDC
    _constructorArgs = [...constructorArgs];
    _constructorArgs[3] = ZERO_ADDRESS;
    implementation = hre.upgrades.deployImplementation(await getContractFactory("ZkSync_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: _constructorArgs,
    });
    await expect(implementation).to.not.be.reverted;

    // Configure none (misconfigured)
    _constructorArgs = [...constructorArgs];
    _constructorArgs[2] = ZERO_ADDRESS;
    _constructorArgs[3] = ZERO_ADDRESS;
    implementation = hre.upgrades.deployImplementation(await getContractFactory("ZkSync_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: _constructorArgs,
    });
    await expect(implementation).to.be.reverted;

    // Configure both (misconfigured)
    _constructorArgs = [...constructorArgs];
    _constructorArgs[2] = zkUSDCBridge.address;
    _constructorArgs[3] = randomAddress();
    implementation = hre.upgrades.deployImplementation(await getContractFactory("ZkSync_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: _constructorArgs,
    });
    await expect(implementation).to.be.reverted;
  });
  it("Only cross domain owner can relay admin root bundles", async function () {
    const { tree } = await constructSingleRelayerRefundTree(l2Dai, await zkSyncSpokePool.callStatic.chainId());
    await expect(zkSyncSpokePool.relayRootBundle(tree.getHexRoot(), mockTreeRoot)).to.be.revertedWith(
      "ONLY_COUNTERPART_GATEWAY"
    );
  });
  it("Bridge tokens to hub pool correctly calls the Standard L2 Bridge for standard ERC20s", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(l2Dai, await zkSyncSpokePool.callStatic.chainId());
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(zkErc20Bridge.withdraw).to.have.been.calledOnce;
    expect(zkErc20Bridge.withdraw).to.have.been.calledWith(hubPool.address, l2Dai, amountToReturn);
  });
  it("Bridge tokens to hub pool correctly calls the Standard L2 Bridge for zkSync Bridged USDC.e", async function () {
    // Redeploy the SpokePool with usdc address -> 0x0
    const usdcAddress = ZERO_ADDRESS;
    const constructorArgs = [weth.address, usdcAddress, zkUSDCBridge.address, cctpTokenMessenger, 60 * 60, 9 * 60 * 60];
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("ZkSync_SpokePool", owner),
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs }
    );
    await zkSyncSpokePool.connect(crossDomainAlias).upgradeTo(implementation);

    const { leaves, tree } = await constructSingleRelayerRefundTree(
      usdc.address,
      await zkSyncSpokePool.callStatic.chainId()
    );
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(zkErc20Bridge.withdraw).to.have.been.calledOnce;
    expect(zkErc20Bridge.withdraw).to.have.been.calledWith(hubPool.address, usdc.address, amountToReturn);
  });
  it("Bridge tokens to hub pool correctly calls the custom USDC L2 Bridge for Circle Bridged USDC", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      usdc.address,
      await zkSyncSpokePool.callStatic.chainId()
    );
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    let allowance = await usdc.allowance(zkSyncSpokePool.address, zkUSDCBridge.address);
    expect(allowance.isZero()).to.be.true;

    await zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have called withdraw() to pull tokens back to L1. Check the correct methods on the gateway are correctly called.
    // zkUSDCBridge is a mocked contract, so the tokens are not actually moved and the approval is intact.
    allowance = await usdc.allowance(zkSyncSpokePool.address, zkUSDCBridge.address);
    expect(allowance.eq(amountToReturn)).to.be.true;

    expect(zkUSDCBridge.withdraw).to.have.been.calledOnce;
    expect(zkUSDCBridge.withdraw).to.have.been.calledWith(hubPool.address, usdc.address, amountToReturn);
  });
  it("Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH, including unwrap", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      weth.address,
      await zkSyncSpokePool.callStatic.chainId()
    );
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    // Executing the refund leaf should cause spoke pool to unwrap WETH to ETH to prepare to send it as msg.value
    // to the ERC20 bridge. This results in a net decrease in WETH balance.
    await expect(() =>
      zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.changeTokenBalance(weth, zkSyncSpokePool, amountToReturn.mul(-1));
    expect(l2Eth.withdraw).to.have.been.calledWithValue(amountToReturn);
    expect(l2Eth.withdraw).to.have.been.calledWith(hubPool.address);
  });
});
