import { zeroAddress } from "./../constants";
import { ethers, expect, Contract, FakeContract, SignerWithAddress, createMock, getContractFactory } from "../utils";
import { hubPoolFixture, enableTokensForLP } from "../HubPool.Fixture";
import { assert } from "console";

let hubPool: Contract, optimismAdapter: Contract, weth: Contract;
let owner: SignerWithAddress, other: SignerWithAddress;
let l1CrossDomainMessenger: FakeContract, l1StandardBridge: FakeContract;

const sampleL2Gas = 5_000_000;

describe("Optimism Chain Adapter", function () {
  beforeEach(async function () {
    [owner, other] = await ethers.getSigners();
    ({ weth, hubPool } = await hubPoolFixture());

    l1CrossDomainMessenger = await createMock("L1CrossDomainMessenger");
    l1StandardBridge = await createMock("L1StandardBridge");

    optimismAdapter = await (
      await getContractFactory("Optimism_Adapter", owner)
    ).deploy(weth.address, hubPool.address, l1CrossDomainMessenger.address, l1StandardBridge.address);
    console.log("B");
  });

  it("Only owner can set l2GasValues", async function () {
    expect(await optimismAdapter.callStatic.l2GasLimit()).to.equal(sampleL2Gas);
    await expect(optimismAdapter.connect(other).setL2GasLimit(sampleL2Gas + 1)).to.be.reverted;
    await optimismAdapter.connect(owner).setL2GasLimit(sampleL2Gas + 1);
    expect(await optimismAdapter.callStatic.l2GasLimit()).to.equal(sampleL2Gas + 1);
  });
  it("Correctly calls appropriate functions when relaying cross chain", async function () {
    // Create an action that will send an L1->L2 token transfer and bundle. For this, create a relayer repayment bundle
    // and check that at it's finalization the L2 bridge contracts are called as expected.
  });
});
