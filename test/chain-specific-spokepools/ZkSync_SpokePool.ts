import { mockTreeRoot, amountToReturn, amountHeldByPool } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  toWei,
  getContractFactory,
  seedContract,
  avmL1ToL2Alias,
} from "../../utils/utils";
import { hre } from "../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { smock } from "@defi-wonderland/smock";

let hubPool: Contract, zkSyncSpokePool: Contract, dai: Contract, weth: Contract;
let l2Dai: string, crossDomainAliasAddress, crossDomainAlias: SignerWithAddress;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let zkErc20Bridge: FakeContract, l2Eth: FakeContract, zkWethBridge: FakeContract;

// TODO: Grab the following from relayer-v2/CONTRACT_ADDRESSES dictionary?
const abiData = {
  erc20DefaultBridge: {
    address: "0x11f943b2c77b743ab90f4a0ae7d5a4e7fca3e102",
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
  wethDefaultBridge: {
    address: "0x5aea5775959fbc2557cc8789bc1bf90a239d9a91",
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
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool } = await hubPoolFixture());

    // Create an alias for the Owner. Impersonate the account. Crate a signer for it and send it ETH.
    crossDomainAliasAddress = avmL1ToL2Alias(owner.address); // @dev Uses same aliasing algorithm as Arbitrum
    await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [crossDomainAliasAddress] });
    crossDomainAlias = await ethers.getSigner(crossDomainAliasAddress);
    await owner.sendTransaction({ to: crossDomainAliasAddress, value: toWei("1") });

    zkErc20Bridge = await smock.fake(abiData.erc20DefaultBridge.abi, { address: abiData.erc20DefaultBridge.address });
    zkWethBridge = await smock.fake(abiData.wethDefaultBridge.abi, { address: abiData.wethDefaultBridge.address });
    l2Eth = await smock.fake(abiData.eth.abi, { address: abiData.eth.address });

    zkSyncSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("ZkSync_SpokePool", owner),
      [0, zkErc20Bridge.address, zkWethBridge.address, owner.address, hubPool.address, weth.address],
      { kind: "uups", unsafeAllow: ["delegatecall"] }
    );

    await seedContract(zkSyncSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("ZkSync_SpokePool", owner),
      { kind: "uups", unsafeAllow: ["delegatecall"] }
    );

    // upgradeTo fails unless called by cross domain admin
    await expect(zkSyncSpokePool.upgradeTo(implementation)).to.be.revertedWith("ONLY_COUNTERPART_GATEWAY");
    await zkSyncSpokePool.connect(crossDomainAlias).upgradeTo(implementation);
  });
  it("Only cross domain owner can set ZKBridge", async function () {
    await expect(zkSyncSpokePool.setZkBridge(rando.address, relayer.address)).to.be.reverted;
    await zkSyncSpokePool.connect(crossDomainAlias).setZkBridge(rando.address, relayer.address);
    expect(await zkSyncSpokePool.zkErc20Bridge()).to.equal(rando.address);
    expect(await zkSyncSpokePool.zkWETHBridge()).to.equal(relayer.address);
  });
  it("Only cross domain owner can relay admin root bundles", async function () {
    const { tree } = await constructSingleRelayerRefundTree(l2Dai, await zkSyncSpokePool.callStatic.chainId());
    await expect(zkSyncSpokePool.relayRootBundle(tree.getHexRoot(), mockTreeRoot)).to.be.revertedWith(
      "ONLY_COUNTERPART_GATEWAY"
    );
  });
  it("Bridge tokens to hub pool correctly calls the Standard L2 Bridge for ERC20", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(l2Dai, await zkSyncSpokePool.callStatic.chainId());
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(zkErc20Bridge.withdraw).to.have.been.calledOnce;
    expect(zkErc20Bridge.withdraw).to.have.been.calledWith(hubPool.address, l2Dai, amountToReturn);
  });
  it("Bridge ETH to hub pool correctly calls the Standard L2 Bridge for WETH", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      weth.address,
      await zkSyncSpokePool.callStatic.chainId()
    );
    await zkSyncSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    await zkSyncSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(zkWethBridge.withdraw).to.have.been.calledOnce;
    expect(zkWethBridge.withdraw).to.have.been.calledWith(hubPool.address, weth.address, amountToReturn);
  });
});
