/* eslint-disable no-unused-expressions */
import {
  amountToLp,
  refundProposalLiveness,
  bondAmount,
  mockRelayerRefundRoot,
  mockSlowRelayRoot,
} from "./../constants";
import {
  ethers,
  expect,
  Contract,
  createFakeFromABI,
  FakeContract,
  SignerWithAddress,
  getContractFactory,
  seedWallet,
  randomAddress,
  createRandomBytes32,
  trimSolanaAddress,
  toWeiWithDecimals,
} from "../../../../utils/utils";
import { hubPoolFixture, enableTokensForLP } from "../fixtures/HubPool.Fixture";
import { constructSingleChainTree } from "../MerkleLib.utils";
import {
  CCTPTokenMessengerInterface,
  CCTPTokenMinterInterface,
  CCTPMessageTransmitterInterface,
} from "../../../../utils/abis";

let hubPool: Contract, solanaAdapter: Contract, weth: Contract, usdc: Contract, timer: Contract, mockSpoke: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let cctpTokenMessenger: FakeContract, cctpMessageTransmitter: FakeContract, cctpTokenMinter: FakeContract;
let solanaSpokePoolBytes32: string,
  solanaUsdcBytes32: string,
  solanaSpokePoolUsdcVaultBytes32: string,
  solanaSpokePoolAddress: string,
  solanaUsdcAddress: string;

const solanaChainId = 1234567890; // TODO: Decide how to represent Solana in Across as it does not have a chainId.
const solanaDomainId = 5;

describe("Solana Chain Adapter", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, mockSpoke, timer, usdc } = await hubPoolFixture());
    await seedWallet(dataWorker, [usdc], weth, amountToLp);
    await seedWallet(liquidityProvider, [usdc], weth, amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth, usdc]);
    for (const token of [weth, usdc]) {
      await token.connect(liquidityProvider).approve(hubPool.address, amountToLp);
      await hubPool.connect(liquidityProvider).addLiquidity(token.address, amountToLp);
      await token.connect(dataWorker).approve(hubPool.address, bondAmount.mul(10));
    }

    cctpTokenMessenger = await createFakeFromABI(CCTPTokenMessengerInterface);
    cctpMessageTransmitter = await createFakeFromABI(CCTPMessageTransmitterInterface);
    cctpTokenMinter = await createFakeFromABI(CCTPTokenMinterInterface);
    cctpTokenMessenger.localMinter.returns(cctpTokenMinter.address);
    cctpTokenMinter.burnLimitsPerMessage.returns(toWeiWithDecimals("1000000", 6));

    solanaSpokePoolBytes32 = createRandomBytes32();
    solanaUsdcBytes32 = createRandomBytes32();
    solanaSpokePoolUsdcVaultBytes32 = createRandomBytes32();

    solanaSpokePoolAddress = trimSolanaAddress(solanaSpokePoolBytes32);
    solanaUsdcAddress = trimSolanaAddress(solanaUsdcBytes32);

    solanaAdapter = await (
      await getContractFactory("Solana_Adapter", owner)
    ).deploy(
      usdc.address,
      cctpTokenMessenger.address,
      cctpMessageTransmitter.address,
      solanaSpokePoolBytes32,
      solanaUsdcBytes32,
      solanaSpokePoolUsdcVaultBytes32
    );

    await hubPool.setCrossChainContracts(solanaChainId, solanaAdapter.address, solanaSpokePoolAddress);
    await hubPool.setPoolRebalanceRoute(solanaChainId, usdc.address, solanaUsdcAddress);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);
    expect(await hubPool.relaySpokePoolAdminFunction(solanaChainId, functionCallData))
      .to.emit(solanaAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(solanaSpokePoolAddress.toLowerCase(), functionCallData);
    expect(cctpMessageTransmitter.sendMessage).to.have.been.calledWith(
      solanaDomainId,
      solanaSpokePoolBytes32,
      functionCallData
    );
  });

  it("Correctly calls the CCTP bridge adapter when attempting to bridge USDC", async function () {
    // Create an action that will send an L1->L2 tokens transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
    const { leaves, tree, tokensSendToL2 } = await constructSingleChainTree(usdc.address, 1, solanaChainId, 6);
    await hubPool
      .connect(dataWorker)
      .proposeRootBundle([3117], 1, tree.getHexRoot(), mockRelayerRefundRoot, mockSlowRelayRoot);
    await timer.setCurrentTime(Number(await timer.getCurrentTime()) + refundProposalLiveness + 1);
    await hubPool.connect(dataWorker).executeRootBundle(...Object.values(leaves[0]), tree.getHexProof(leaves[0]));

    // Adapter should have approved CCTP TokenMessenger to spend its ERC20, but the fake instance does not pull them.
    expect(await usdc.allowance(hubPool.address, cctpTokenMessenger.address)).to.equal(tokensSendToL2);

    // The correct functions should have been called on the CCTP TokenMessenger contract
    expect(cctpTokenMessenger.depositForBurn).to.have.been.calledOnce;
    expect(cctpTokenMessenger.depositForBurn).to.have.been.calledWith(
      ethers.BigNumber.from(tokensSendToL2),
      solanaDomainId,
      solanaSpokePoolUsdcVaultBytes32,
      usdc.address
    );
  });

  it("Correctly translates setEnableRoute calls to the spoke pool", async function () {
    // Enable deposits for USDC on Solana.
    const destinationChainId = 1;
    const depositsEnabled = true;
    await hubPool.setDepositRoute(solanaChainId, destinationChainId, solanaUsdcAddress, depositsEnabled);

    // Solana spoke pool expects to receive full bytes32 token address and uint64 for chainId.
    const solanaInterface = new ethers.utils.Interface(["function setEnableRoute(bytes32, uint64, bool)"]);
    const solanaMessage = solanaInterface.encodeFunctionData("setEnableRoute", [
      solanaUsdcBytes32,
      destinationChainId,
      depositsEnabled,
    ]);
    expect(cctpMessageTransmitter.sendMessage).to.have.been.calledWith(
      solanaDomainId,
      solanaSpokePoolBytes32,
      solanaMessage
    );
  });
});
