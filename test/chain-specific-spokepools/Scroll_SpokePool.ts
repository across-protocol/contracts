import { mockTreeRoot, amountHeldByPool } from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedContract,
  createFakeFromABI,
  randomAddress,
} from "../../utils/utils";
import { hre } from "../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";

const NO_ADMIN_REVERT = "Sender must be admin";

const gatewayRouterABI = [
  {
    inputs: [
      {
        internalType: "address",
        name: "_token",
        type: "address",
      },
      {
        internalType: "address",
        name: "_to",
        type: "address",
      },
      {
        internalType: "uint256",
        name: "_amount",
        type: "uint256",
      },
      {
        internalType: "uint256",
        name: "_gasLimit",
        type: "uint256",
      },
    ],
    name: "withdrawERC20",
    outputs: [],
    stateMutability: "payable",
    type: "function",
  },
];

const messengerABI = [
  {
    inputs: [],
    name: "xDomainMessageSender",
    outputs: [
      {
        internalType: "address",
        name: "",
        type: "address",
      },
    ],
    stateMutability: "view",
    type: "function",
  },
];

/**
 * For equivalency with Smock, we need to use the same BigNumber type.
 * @param value A string or number to convert to a BigNumber
 * @returns A BigNumber
 */
function toBN(value: string | number) {
  return ethers.BigNumber.from(value);
}

let hubPool: Contract, scrollSpokePool: Contract, dai: Contract, weth: Contract;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress;
let l2GatewayRouter: FakeContract, l2Messenger: FakeContract;

describe("Scroll Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, dai, hubPool } = await hubPoolFixture());

    // Create the fake messenger and l2gateway router.
    l2GatewayRouter = await createFakeFromABI(gatewayRouterABI);
    l2Messenger = await createFakeFromABI(messengerABI);

    scrollSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Scroll_SpokePool", owner),
      [l2GatewayRouter.address, l2Messenger.address, 0, owner.address, hubPool.address],
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address, 3600, 7200] }
    );

    await seedContract(scrollSpokePool, relayer, [dai], weth, amountHeldByPool);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("Scroll_SpokePool", owner),
      { kind: "uups", unsafeAllow: ["delegatecall"], constructorArgs: [weth.address, 60 * 60, 9 * 60 * 60] }
    );

    await expect(scrollSpokePool.connect(rando).upgradeTo(implementation)).to.be.revertedWith(NO_ADMIN_REVERT);

    l2Messenger.xDomainMessageSender.returns(owner.address);
    await scrollSpokePool.connect(owner).upgradeTo(implementation);
  });

  it("Only cross domain owner can set the new L2GatewayRouter", async function () {
    const newL2GatewayRouter = randomAddress();
    await expect(scrollSpokePool.connect(rando).setL2GatewayRouter(rando.address)).to.be.reverted;
    l2Messenger.xDomainMessageSender.returns(owner.address);
    await expect(scrollSpokePool.connect(owner).setL2GatewayRouter(newL2GatewayRouter)).to.not.be.reverted;
    const resolvedNewL2GatewayRouter = await scrollSpokePool.l2GatewayRouter();
    expect(resolvedNewL2GatewayRouter).to.equal(newL2GatewayRouter);
  });

  it("Only cross domain owner can set the new L2Messenger", async function () {
    const newL2Messenger = randomAddress();
    await expect(scrollSpokePool.connect(rando).setL2ScrollMessenger(rando.address)).to.be.reverted;
    l2Messenger.xDomainMessageSender.returns(owner.address);
    await expect(scrollSpokePool.connect(owner).setL2ScrollMessenger(newL2Messenger)).to.not.be.reverted;
    const resolvedNewL2Messenger = await scrollSpokePool.l2ScrollMessenger();
    expect(resolvedNewL2Messenger).to.equal(newL2Messenger);
  });

  it("Only cross domain owner can relay admin root bundles", async function () {
    const { tree } = await constructSingleRelayerRefundTree(dai.address, await scrollSpokePool.callStatic.chainId());
    await expect(scrollSpokePool.relayRootBundle(tree.getHexRoot(), mockTreeRoot)).to.be.revertedWith(NO_ADMIN_REVERT);
  });

  it("Bridge tokens to hub pool correctly calls the L2 Token Bridge for ERC20", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      dai.address,
      await scrollSpokePool.callStatic.chainId()
    );
    const amountToReturn = leaves[0].amountToReturn;
    l2Messenger.xDomainMessageSender.returns(owner.address);
    await scrollSpokePool.connect(owner).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    l2Messenger.xDomainMessageSender.reset();
    await scrollSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    expect(l2GatewayRouter.withdrawERC20).to.have.been.calledWith(
      dai.address,
      hubPool.address,
      toBN(amountToReturn.toString()),
      toBN(0)
    );
  });
});
