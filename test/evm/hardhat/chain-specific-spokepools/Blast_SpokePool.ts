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
  randomAddress,
} from "../../../../utils/utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import { hre } from "../../../../utils/utils.hre";

import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { IHypXERC20Router__factory } from "../../../../typechain";

let hubPool: Contract, blastSpokePool: Contract, dai: Contract, weth: Contract, l2EzETH: Contract, usdb: Contract;
let l2Dai: string, l2Usdc: string;
let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, yieldRecipient: SignerWithAddress;
let crossDomainMessenger: FakeContract,
  l2CctpTokenMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  l2HypXERC20Router: FakeContract;

// Constants needed for Blast_SpokePool constructor but not directly related to XERC20 test
const USDB_ADDRESS = "0x4300000000000000000000000000000000000003"; // This would be the real address on Blast mainnet
const L1_USDB_ADDRESS = "0x6B175474E89094C44Da98b954EedeAC495271d0F"; // DAI on mainnet

describe("Blast Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando, yieldRecipient] = await ethers.getSigners();
    ({ weth, dai, l2Dai, hubPool, l2Usdc } = await hubPoolFixture());

    // Create ezETH token for XERC20 testing
    l2EzETH = await (await getContractFactory("ExpandedERC20", owner)).deploy("ezETH XERC20 coin.", "ezETH", 18);
    await l2EzETH.addMember(TokenRolesEnum.MINTER, owner.address);

    // Create USDB token (Blast's yield-bearing stablecoin) - needed for constructor
    usdb = await (await getContractFactory("ExpandedERC20", owner)).deploy("USDB", "USDB", 18);
    await usdb.addMember(TokenRolesEnum.MINTER, owner.address);

    // Create the fake contracts for Blast L2
    crossDomainMessenger = await createFake("L2CrossDomainMessenger", "0x4200000000000000000000000000000000000007");
    l2CctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    l2CctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));
    l2HypXERC20Router = await createTypedFakeFromABI([...IHypXERC20Router__factory.abi]);

    // Impersonate the cross-domain messenger
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [crossDomainMessenger.address],
    });
    await owner.sendTransaction({ to: crossDomainMessenger.address, value: toWei("1") });

    // Deploy MockBlast_SpokePool instead of Blast_SpokePool
    const blastRetriever = randomAddress(); // A random address to act as the blast retriever

    blastSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("MockBlast_SpokePool", owner),
      [0, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [
          weth.address,
          60 * 60,
          9 * 60 * 60,
          l2Usdc,
          l2CctpTokenMessenger.address,
          usdb.address,
          L1_USDB_ADDRESS,
          yieldRecipient.address,
          blastRetriever,
        ],
      }
    );

    await seedContract(blastSpokePool, relayer, [dai, l2EzETH, usdb], weth, amountHeldByPool);

    // Set up XERC20 router for l2EzETH using the cross-domain messenger pattern
    // The key is to set xDomainMessageSender correctly and use the messenger's wallet
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await blastSpokePool
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
      await blastSpokePool.callStatic.chainId(),
      ezETHSendAmount
    );

    // Set up admin permission to relay root bundle
    crossDomainMessenger.xDomainMessageSender.returns(owner.address);
    await blastSpokePool.connect(crossDomainMessenger.wallet).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    crossDomainMessenger.xDomainMessageSender.reset();

    await blastSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: hypXERC20Fee });

    // Adapter should have approved l2HypXERC20Router to spend its ERC20
    expect(await l2EzETH.allowance(blastSpokePool.address, l2HypXERC20Router.address)).to.equal(ezETHSendAmount);

    const hubPoolHypDomainId = 1;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledOnce;
    expect(l2HypXERC20Router.transferRemote).to.have.been.calledWith(
      hubPoolHypDomainId,
      ethers.utils.hexZeroPad(hubPool.address, 32).toLowerCase(),
      ezETHSendAmount
    );
  });
});
