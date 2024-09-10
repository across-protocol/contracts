import * as consts from "../constants";
import {
  ethers,
  expect,
  Contract,
  FakeContract,
  SignerWithAddress,
  createFake,
  toWei,
  defaultAbiCoder,
  toBN,
} from "../../../utils/utils";
import { getContractFactory, seedWallet, randomAddress } from "../../../utils/utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";

let hubPool: Contract, arbitrumAdapter: Contract, weth: Contract, mockSpoke: Contract;
let gatewayAddress: string;
let owner: SignerWithAddress, liquidityProvider: SignerWithAddress, refundAddress: SignerWithAddress;
let l1ERC20GatewayRouter: FakeContract;

const arbitrumChainId = 42161;

describe("Arbitrum Chain SendTokens Emergency Adapter", function () {
  beforeEach(async function () {
    [owner, liquidityProvider, refundAddress] = await ethers.getSigners();
    ({ weth, hubPool, mockSpoke } = await hubPoolFixture());

    // Send tokens to HubPool directly.
    await seedWallet(owner, [], weth, consts.amountToLp);
    await weth.transfer(hubPool.address, consts.amountToLp);

    l1ERC20GatewayRouter = await createFake("ArbitrumMockErc20GatewayRouter");
    gatewayAddress = randomAddress();
    l1ERC20GatewayRouter.getGateway.returns(gatewayAddress);

    arbitrumAdapter = await (
      await getContractFactory("Arbitrum_SendTokensAdapter", owner)
    ).deploy(l1ERC20GatewayRouter.address, refundAddress.address);

    // Seed the HubPool some funds so it can send L1->L2 messages.
    await hubPool.connect(liquidityProvider).loadEthForL2Calls({ value: toWei("1") });
    await hubPool.setCrossChainContracts(arbitrumChainId, arbitrumAdapter.address, mockSpoke.address);
  });

  it("relayMessage sends desired ERC20 in specified amount to SpokePool", async function () {
    const tokensToSendToL2 = consts.amountToLp;
    const message = defaultAbiCoder.encode(["address", "uint256"], [weth.address, tokensToSendToL2]);

    expect(await hubPool.relaySpokePoolAdminFunction(arbitrumChainId, message)).to.changeEtherBalances(
      [l1ERC20GatewayRouter],
      [toBN(consts.sampleL2MaxSubmissionCost).add(toBN(consts.sampleL2Gas).mul(consts.sampleL2GasPrice))]
    );
    expect(l1ERC20GatewayRouter.outboundTransferCustomRefund).to.have.been.calledOnce;
    expect(await weth.allowance(hubPool.address, gatewayAddress)).to.equal(tokensToSendToL2);
    const maxSubmissionCostMessage = defaultAbiCoder.encode(
      ["uint256", "bytes"],
      [consts.sampleL2MaxSubmissionCost, "0x"]
    );
    expect(l1ERC20GatewayRouter.outboundTransferCustomRefund).to.have.been.calledWith(
      weth.address,
      refundAddress.address,
      mockSpoke.address,
      tokensToSendToL2,
      consts.sampleL2GasSendTokens,
      consts.sampleL2GasPrice,
      maxSubmissionCostMessage
    );
  });
});
