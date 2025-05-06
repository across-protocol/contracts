import { smock } from "@defi-wonderland/smock";

import { mockTreeRoot, amountToReturn, amountHeldByPool, zeroAddress } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedContract,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

let hubPool: Contract, polygonZkEvmSpokePool: Contract, dai: Contract, weth: Contract;
let owner: SignerWithAddress,
  relayer: SignerWithAddress,
  polygonZkEvmBridgeSigner: SignerWithAddress,
  rando: SignerWithAddress;
let polygonZkEvmBridge: FakeContract;

const polygonZkEvmL1NetworkId = 0;

const polygonZkEvmBridgeAbi = [
  {
    inputs: [
      { internalType: "uint32", name: "destinationNetwork", type: "uint32" },
      { internalType: "address", name: "destinationAddress", type: "address" },
      { internalType: "uint256", name: "amount", type: "uint256" },
      { internalType: "address", name: "token", type: "address" },
      { internalType: "bool", name: "forceUpdateGlobalExitRoot", type: "bool" },
      { internalType: "bytes", name: "permitData", type: "bytes" },
    ],
    name: "bridgeAsset",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
  {
    inputs: [
      { internalType: "uint32", name: "destinationNetwork", type: "uint32" },
      { internalType: "address", name: "destinationAddress", type: "address" },
      { internalType: "bool", name: "forceUpdateGlobalExitRoot", type: "bool" },
      { internalType: "bytes", name: "metadata", type: "bytes" },
    ],
    name: "bridgeMessage",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

describe("Polygon zkEVM Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, polygonZkEvmBridgeSigner, rando] = await ethers.getSigners();
    ({ weth, dai, hubPool } = await hubPoolFixture());

    polygonZkEvmBridge = await smock.fake(polygonZkEvmBridgeAbi, {
      address: polygonZkEvmBridgeSigner.address,
    });

    polygonZkEvmSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("PolygonZkEVM_SpokePool", owner),
      [polygonZkEvmBridge.address, 0, owner.address, hubPool.address],
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60] }
    );

    await seedContract(polygonZkEvmSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    const implementation = await hre.upgrades.deployImplementation(await getContractFactory("Linea_SpokePool", owner), {
      kind: "uups",
      unsafeAllow: ["delegatecall"],
      constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60],
    });

    const upgradeData = polygonZkEvmSpokePool.interface.encodeFunctionData("upgradeTo", [implementation]);

    // Reverts if called directly
    await expect(polygonZkEvmSpokePool.connect(rando).upgradeTo(implementation)).to.be.revertedWith(
      "AdminCallNotValidated()"
    );
    // Reverts if called not from bridge
    await expect(
      polygonZkEvmSpokePool.connect(rando).onMessageReceived(owner.address, polygonZkEvmL1NetworkId, upgradeData)
    ).to.be.revertedWith("CallerNotBridge()");
    // Reverts if called by non-admin
    await expect(
      polygonZkEvmSpokePool
        .connect(polygonZkEvmBridgeSigner)
        .onMessageReceived(rando.address, polygonZkEvmL1NetworkId, upgradeData)
    ).to.be.revertedWith("OriginSenderNotCrossDomain()");
    // Reverts if source network is not L1
    await expect(
      polygonZkEvmSpokePool.connect(polygonZkEvmBridgeSigner).onMessageReceived(owner.address, 1, upgradeData)
    ).to.be.revertedWith("SourceChainNotHubChain()");

    await polygonZkEvmSpokePool
      .connect(polygonZkEvmBridgeSigner)
      .onMessageReceived(owner.address, polygonZkEvmL1NetworkId, upgradeData);
  });

  it("Only cross domain owner can set l2PolygonZkEVMBridge", async function () {
    const setL2BridgeData = polygonZkEvmSpokePool.interface.encodeFunctionData("setL2PolygonZkEVMBridge", [
      rando.address,
    ]);

    // Reverts if called directly
    await expect(polygonZkEvmSpokePool.connect(rando).setL2PolygonZkEVMBridge(rando.address)).to.be.revertedWith(
      "AdminCallNotValidated()"
    );
    // Reverts if called not from bridge
    await expect(
      polygonZkEvmSpokePool.connect(rando).onMessageReceived(owner.address, polygonZkEvmL1NetworkId, setL2BridgeData)
    ).to.be.revertedWith("CallerNotBridge()");
    // Reverts if called by non-admin
    await expect(
      polygonZkEvmSpokePool
        .connect(polygonZkEvmBridgeSigner)
        .onMessageReceived(rando.address, polygonZkEvmL1NetworkId, setL2BridgeData)
    ).to.be.revertedWith("OriginSenderNotCrossDomain()");
    // Reverts if source network is not L1
    await expect(
      polygonZkEvmSpokePool.connect(polygonZkEvmBridgeSigner).onMessageReceived(owner.address, 1, setL2BridgeData)
    ).to.be.revertedWith("SourceChainNotHubChain()");

    await polygonZkEvmSpokePool
      .connect(polygonZkEvmBridgeSigner)
      .onMessageReceived(owner.address, polygonZkEvmL1NetworkId, setL2BridgeData);
    expect(await polygonZkEvmSpokePool.l2PolygonZkEVMBridge()).to.equal(rando.address);
  });

  it("Bridge tokens to hub pool correctly calls the L2 Token Bridge for ETH", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      weth.address,
      await polygonZkEvmSpokePool.callStatic.chainId()
    );
    const fnData = polygonZkEvmSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);
    await polygonZkEvmSpokePool
      .connect(polygonZkEvmBridgeSigner)
      .onMessageReceived(owner.address, polygonZkEvmL1NetworkId, fnData);
    await polygonZkEvmSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent ETH back to L1. Check the correct methods on the gateway are correctly called.
    expect(polygonZkEvmBridge.bridgeAsset).to.have.been.calledWith(
      polygonZkEvmL1NetworkId,
      hubPool.address,
      amountToReturn,
      zeroAddress,
      true,
      "0x"
    );
  });

  it("Bridge tokens to hub pool correctly calls the L2 Token Bridge for ERC20", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await polygonZkEvmSpokePool.callStatic.chainId()
    );
    const fnData = polygonZkEvmSpokePool.interface.encodeFunctionData("relayRootBundle", [
      tree.getHexRoot(),
      mockTreeRoot,
    ]);
    await polygonZkEvmSpokePool
      .connect(polygonZkEvmBridgeSigner)
      .onMessageReceived(owner.address, polygonZkEvmL1NetworkId, fnData);
    await polygonZkEvmSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(polygonZkEvmBridge.bridgeAsset).to.have.been.calledWith(
      polygonZkEvmL1NetworkId,
      hubPool.address,
      amountToReturn,
      dai.address,
      true,
      "0x"
    );
  });
});
