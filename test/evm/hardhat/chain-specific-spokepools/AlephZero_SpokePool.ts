import { ethers, expect, Contract, FakeContract, SignerWithAddress, getContractFactory } from "../../../../utils/utils";
import { hre } from "../../../../utils/utils.hre";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";
import { smock } from "@defi-wonderland/smock";

describe("AlephZero Spoke Pool", function () {
  let hubPool: Contract;
  let spokePool: Contract;
  let weth: Contract;
  let usdc: Contract;
  let owner: SignerWithAddress;
  let cctpTokenMessenger: FakeContract;
  let mockL2Gateway: FakeContract;

  const depositQuoteTimeBuffer = 60 * 60;
  const fillDeadlineBuffer = 9 * 60 * 60;

  const tokenMessengerAbi = [
    {
      inputs: [],
      name: "localToken",
      outputs: [{ internalType: "address", name: "", type: "address" }],
      stateMutability: "view",
      type: "function",
    },
  ];

  const l2GatewayAbi = [
    {
      inputs: [
        { name: "_l1Token", type: "address" },
        { name: "_to", type: "address" },
        { name: "_amount", type: "uint256" },
        { name: "_data", type: "bytes" },
      ],
      name: "outboundTransfer",
      outputs: [{ name: "", type: "bytes" }],
      stateMutability: "payable",
      type: "function",
    },
  ];

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());

    cctpTokenMessenger = await smock.fake(tokenMessengerAbi);
    mockL2Gateway = await smock.fake(l2GatewayAbi);

    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("AlephZero_SpokePool", owner),
      [
        0, // _initialDepositId
        mockL2Gateway.address, // _l2GatewayRouter
        owner.address, // _crossDomainAdmin
        hubPool.address, // _withdrawalRecipient
      ],
      {
        kind: "uups",
        unsafeAllow: ["delegatecall"],
        constructorArgs: [
          weth.address,
          depositQuoteTimeBuffer,
          fillDeadlineBuffer,
          usdc.address,
          cctpTokenMessenger.address,
        ],
      }
    );
  });

  describe("Constructor", function () {
    it("Should properly pass constructor parameters to parent contract", async function () {
      expect(await spokePool.wrappedNativeToken()).to.equal(weth.address);
      expect(await spokePool.depositQuoteTimeBuffer()).to.equal(depositQuoteTimeBuffer);
      expect(await spokePool.fillDeadlineBuffer()).to.equal(fillDeadlineBuffer);
      expect(await spokePool.usdcToken()).to.equal(usdc.address);
      expect(await spokePool.cctpTokenMessenger()).to.equal(cctpTokenMessenger.address);
    });
  });
});
