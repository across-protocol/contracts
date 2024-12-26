/* eslint-disable node/no-missing-import */
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

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ weth, usdc, hubPool } = await hubPoolFixture());
    cctpTokenMessenger = await smock.fake(tokenMessengerAbi);

    spokePool = await hre.upgrades.deployProxy(
      await getContractFactory("AlephZero_SpokePool", owner),
      [0, owner.address, hubPool.address],
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
