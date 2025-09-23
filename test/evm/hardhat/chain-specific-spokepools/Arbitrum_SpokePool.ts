import { mockTreeRoot, amountToReturn, amountHeldByPool, zeroAddress } from "../constants";
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
  avmL1ToL2Alias,
  createFakeFromABI,
  createTypedFakeFromABI,
  BigNumber,
  randomBytes32,
  toWeiWithDecimals,
  getOftEid,
} from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { constructSingleRelayerRefundTree } from "../MerkleLib.utils";
import { CCTPTokenMessengerInterface, CCTPTokenMinterInterface } from "../../../../utils/abis";
import {
  MessagingFeeStructOutput,
  MessagingReceiptStructOutput,
  OFTReceiptStructOutput,
  SendParamStruct,
} from "../../../../typechain/contracts/interfaces/IOFT";
import { IOFT__factory } from "../../../../typechain/factories/contracts/interfaces/IOFT__factory";
import { CHAIN_IDs } from "@across-protocol/constants";

let hubPool: Contract, arbitrumSpokePool: Contract, dai: Contract, weth: Contract, l2UsdtContract: Contract;
let l2Weth: string, l2Dai: string, l2Usdc: string, crossDomainAliasAddress;

let owner: SignerWithAddress, relayer: SignerWithAddress, rando: SignerWithAddress, crossDomainAlias: SignerWithAddress;
let l2GatewayRouter: FakeContract,
  l2CctpTokenMessenger: FakeContract,
  cctpTokenMinter: FakeContract,
  l2OftMessenger: FakeContract;

const oftHubEid = getOftEid(CHAIN_IDs.MAINNET);

describe("Arbitrum Spoke Pool", function () {
  beforeEach(async function () {
    [owner, relayer, rando] = await ethers.getSigners();
    ({ weth, l2Weth, dai, l2Dai, hubPool, l2Usdc, l2UsdtContract } = await hubPoolFixture());

    // Create an alias for the Owner. Impersonate the account. Crate a signer for it and send it ETH.
    crossDomainAliasAddress = avmL1ToL2Alias(owner.address);
    await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [crossDomainAliasAddress] });
    crossDomainAlias = await ethers.getSigner(crossDomainAliasAddress);
    await owner.sendTransaction({ to: crossDomainAliasAddress, value: toWei("1") });

    l2GatewayRouter = await createFake("L2GatewayRouter");
    l2CctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    l2CctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWei("1000000"));
    l2OftMessenger = await createTypedFakeFromABI([...IOFT__factory.abi]);

    arbitrumSpokePool = await hre.upgrades.deployProxy(
      await getContractFactory("Arbitrum_SpokePool", owner),
      [0, l2GatewayRouter.address, owner.address, hubPool.address],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [l2Weth, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address, oftHubEid, toWei("1")],
      }
    );

    await seedContract(arbitrumSpokePool, relayer, [dai], weth, amountHeldByPool);
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, dai.address);
  });

  it("Only cross domain owner upgrade logic contract", async function () {
    // TODO: Could also use upgrades.prepareUpgrade but I'm unclear of differences
    const implementation = await hre.upgrades.deployImplementation(
      await getContractFactory("Arbitrum_SpokePool", owner),
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [l2Weth, 60 * 60, 9 * 60 * 60, l2Usdc, l2CctpTokenMessenger.address, oftHubEid, toWei("1")],
      }
    );

    // upgradeTo fails unless called by cross domain admin
    await expect(arbitrumSpokePool.upgradeTo(implementation)).to.be.revertedWith("ONLY_COUNTERPART_GATEWAY");
    await arbitrumSpokePool.connect(crossDomainAlias).upgradeTo(implementation);
  });

  it("Only cross domain owner can set L2GatewayRouter", async function () {
    await expect(arbitrumSpokePool.setL2GatewayRouter(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setL2GatewayRouter(rando.address);
    expect(await arbitrumSpokePool.l2GatewayRouter()).to.equal(rando.address);
  });

  it("Only cross domain owner can whitelist a token pair", async function () {
    await expect(arbitrumSpokePool.whitelistToken(l2Dai, dai.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, dai.address);
    expect(await arbitrumSpokePool.whitelistedTokens(l2Dai)).to.equal(dai.address);
  });

  it("Only cross domain owner can set the cross domain admin", async function () {
    await expect(arbitrumSpokePool.setCrossDomainAdmin(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setCrossDomainAdmin(rando.address);
    expect(await arbitrumSpokePool.crossDomainAdmin()).to.equal(rando.address);
  });

  it("Only cross domain owner can set the hub pool address", async function () {
    await expect(arbitrumSpokePool.setWithdrawalRecipient(rando.address)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).setWithdrawalRecipient(rando.address);
    expect(await arbitrumSpokePool.withdrawalRecipient()).to.equal(rando.address);
  });

  it("Only cross domain owner can initialize a relayer refund", async function () {
    await expect(arbitrumSpokePool.relayRootBundle(mockTreeRoot, mockTreeRoot)).to.be.reverted;
    await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(mockTreeRoot, mockTreeRoot);
    expect((await arbitrumSpokePool.rootBundles(0)).slowRelayRoot).to.equal(mockTreeRoot);
    expect((await arbitrumSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(mockTreeRoot);
  });

  it("Only cross domain owner can delete a relayer refund", async function () {
    await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(mockTreeRoot, mockTreeRoot);
    await expect(arbitrumSpokePool.emergencyDeleteRootBundle(0)).to.be.reverted;
    await expect(arbitrumSpokePool.connect(crossDomainAlias).emergencyDeleteRootBundle(0)).to.not.be.reverted;
    expect((await arbitrumSpokePool.rootBundles(0)).slowRelayRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
    expect((await arbitrumSpokePool.rootBundles(0)).relayerRefundRoot).to.equal(ethers.utils.hexZeroPad("0x0", 32));
  });

  it("Bridge tokens to hub pool correctly calls the Standard L2 Gateway router", async function () {
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2Dai,
      await arbitrumSpokePool.callStatic.chainId()
    );
    await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    // Reverts if route from arbitrum to mainnet for l2Dai isn't whitelisted.
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, zeroAddress);
    await expect(
      arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
    ).to.be.revertedWith("Uninitialized mainnet token");
    await arbitrumSpokePool.connect(crossDomainAlias).whitelistToken(l2Dai, dai.address);

    await arbitrumSpokePool.connect(relayer).executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]));

    // This should have sent tokens back to L1. Check the correct methods on the gateway are correctly called.
    // outboundTransfer is overloaded in the arbitrum gateway. Define the interface to check the method is called.
    const functionKey = "outboundTransfer(address,address,uint256,bytes)";
    expect(l2GatewayRouter[functionKey]).to.have.been.calledOnce;
    expect(l2GatewayRouter[functionKey]).to.have.been.calledWith(dai.address, hubPool.address, amountToReturn, "0x");
  });

  it("Bridge tokens to hub pool correctly using the OFT messaging for L2 USDT token", async function () {
    l2OftMessenger.token.returns(l2UsdtContract.address);
    await arbitrumSpokePool.connect(crossDomainAlias).setOftMessenger(l2UsdtContract.address, l2OftMessenger.address);

    l2OftMessenger.token.returns(l2UsdtContract.address);
    await arbitrumSpokePool.connect(crossDomainAlias).setOftMessenger(l2UsdtContract.address, l2OftMessenger.address);

    const l2UsdtSendAmount = BigNumber.from("1234567");
    const { leaves, tree } = await constructSingleRelayerRefundTree(
      l2UsdtContract.address,
      await arbitrumSpokePool.callStatic.chainId(),
      l2UsdtSendAmount
    );
    await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);

    const oftNativeFee = toWeiWithDecimals("1", 9).mul(200_000); // 1 GWEI gas price * 200,000 gas cost

    // set up `quoteSend` return val
    const msgFeeStruct: MessagingFeeStructOutput = [
      oftNativeFee, // nativeFee
      BigNumber.from(0), // lzTokenFee
    ] as MessagingFeeStructOutput;
    l2OftMessenger.quoteSend.returns(msgFeeStruct);

    // set up `send` return val
    const msgReceipt: MessagingReceiptStructOutput = [
      randomBytes32(), // guid
      BigNumber.from("1"), // nonce
      msgFeeStruct, // fee
    ] as MessagingReceiptStructOutput;

    const oftReceipt: OFTReceiptStructOutput = [l2UsdtSendAmount, l2UsdtSendAmount] as OFTReceiptStructOutput;

    l2OftMessenger.send.returns([msgReceipt, oftReceipt]);

    await arbitrumSpokePool
      .connect(relayer)
      .executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: oftNativeFee });
    // Adapter should have approved gateway to spend its ERC20.
    expect(await l2UsdtContract.allowance(arbitrumSpokePool.address, l2OftMessenger.address)).to.equal(
      l2UsdtSendAmount
    );

    const sendParam: SendParamStruct = {
      dstEid: oftHubEid,
      to: ethers.utils.hexZeroPad(hubPool.address, 32).toLowerCase(),
      amountLD: l2UsdtSendAmount,
      minAmountLD: l2UsdtSendAmount,
      extraOptions: "0x",
      composeMsg: "0x",
      oftCmd: "0x",
    };

    // We should have called send on the l2OftMessenger once with correct params
    expect(l2OftMessenger.send).to.have.been.calledOnce;
    expect(l2OftMessenger.send).to.have.been.calledWith(sendParam, msgFeeStruct, arbitrumSpokePool.address);
  });

  describe("OFT bridging", function () {
    const l2UsdtSendAmount = BigNumber.from("1234567");
    let leaves: any, tree: any;

    beforeEach(async function () {
      l2OftMessenger.token.returns(l2UsdtContract.address);
      await arbitrumSpokePool.connect(crossDomainAlias).setOftMessenger(l2UsdtContract.address, l2OftMessenger.address);

      const treeResult = await constructSingleRelayerRefundTree(
        l2UsdtContract.address,
        await arbitrumSpokePool.callStatic.chainId(),
        l2UsdtSendAmount
      );
      leaves = treeResult.leaves;
      tree = treeResult.tree;
      await arbitrumSpokePool.connect(crossDomainAlias).relayRootBundle(tree.getHexRoot(), mockTreeRoot);
    });

    it("reverts with OftLzFeeNotZero if lzTokenFee is not zero", async function () {
      const nativeFee = toWei("0.1");
      const msgFeeStruct: MessagingFeeStructOutput = [
        nativeFee,
        BigNumber.from(1), // lzTokenFee
      ] as MessagingFeeStructOutput;
      l2OftMessenger.quoteSend.returns(msgFeeStruct);

      await expect(
        arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: nativeFee })
      ).to.be.revertedWith("OftLzFeeNotZero");
    });

    it("reverts with OftFeeCapExceeded if nativeFee is too high", async function () {
      const highNativeFee = toWei("2"); // Higher than oftFeeCap (1 ETH)
      const msgFeeStruct: MessagingFeeStructOutput = [
        highNativeFee, // nativeFee
        BigNumber.from(0), // lzTokenFee
      ] as MessagingFeeStructOutput;
      l2OftMessenger.quoteSend.returns(msgFeeStruct);

      await expect(
        arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]), { value: highNativeFee })
      ).to.be.revertedWith("OftFeeCapExceeded");
    });

    it("reverts with OFTFeeUnderpaid if caller does not supply the required OFT fee", async function () {
      const nativeFee = toWei("0.1");
      const msgFeeStruct: MessagingFeeStructOutput = [
        nativeFee, // nativeFee
        BigNumber.from(0), // lzTokenFee
      ] as MessagingFeeStructOutput;
      l2OftMessenger.quoteSend.returns(msgFeeStruct);

      await expect(
        arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.be.revertedWith("OFTFeeUnderpaid");
    });

    it("reverts with OftIncorrectAmountReceivedLD if OFT receipt has wrong received amount", async function () {
      const msgFeeStruct: MessagingFeeStructOutput = [BigNumber.from(0), BigNumber.from(0)] as MessagingFeeStructOutput;
      l2OftMessenger.quoteSend.returns(msgFeeStruct);

      const msgReceipt: MessagingReceiptStructOutput = [
        randomBytes32(),
        BigNumber.from(1),
        msgFeeStruct,
      ] as MessagingReceiptStructOutput;
      const oftReceipt: OFTReceiptStructOutput = [
        l2UsdtSendAmount,
        l2UsdtSendAmount.sub(1), // Incorrect received amount
      ] as OFTReceiptStructOutput;
      l2OftMessenger.send.returns([msgReceipt, oftReceipt]);

      await expect(
        arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.be.revertedWith("OftIncorrectAmountReceivedLD");
    });

    it("reverts with OftIncorrectAmountSentLD if OFT receipt has wrong sent amount", async function () {
      const msgFeeStruct: MessagingFeeStructOutput = [BigNumber.from(0), BigNumber.from(0)] as MessagingFeeStructOutput;
      l2OftMessenger.quoteSend.returns(msgFeeStruct);

      const msgReceipt: MessagingReceiptStructOutput = [
        randomBytes32(),
        BigNumber.from(1),
        msgFeeStruct,
      ] as MessagingReceiptStructOutput;
      const oftReceipt: OFTReceiptStructOutput = [
        l2UsdtSendAmount.sub(1), // Incorrect sent amount
        l2UsdtSendAmount,
      ] as OFTReceiptStructOutput;
      l2OftMessenger.send.returns([msgReceipt, oftReceipt]);

      await expect(
        arbitrumSpokePool.executeRelayerRefundLeaf(0, leaves[0], tree.getHexProof(leaves[0]))
      ).to.be.revertedWith("OftIncorrectAmountSentLD");
    });
  });

  it("Cross domain owner can set and remove an OFT messenger", async function () {
    l2OftMessenger.token.returns(l2UsdtContract.address);

    await expect(arbitrumSpokePool.setOftMessenger(l2UsdtContract.address, l2OftMessenger.address)).to.be.reverted;

    await arbitrumSpokePool.connect(crossDomainAlias).setOftMessenger(l2UsdtContract.address, l2OftMessenger.address);
    expect(await arbitrumSpokePool.oftMessengers(l2UsdtContract.address)).to.equal(l2OftMessenger.address);

    await expect(arbitrumSpokePool.setOftMessenger(l2UsdtContract.address, zeroAddress)).to.be.reverted;

    await arbitrumSpokePool.connect(crossDomainAlias).setOftMessenger(l2UsdtContract.address, zeroAddress);
    expect(await arbitrumSpokePool.oftMessengers(l2UsdtContract.address)).to.equal(zeroAddress);
  });
});
