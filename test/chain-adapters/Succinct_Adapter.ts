import { ethers, expect, Contract, FakeContract, SignerWithAddress } from "../utils";
import { createFake, getContractFactory, randomAddress } from "../utils";
import { hubPoolFixture } from "../fixtures/HubPool.Fixture";

let hubPool: Contract, succinctAdapter: Contract, mockSpoke: Contract;
let owner: SignerWithAddress;
let telepathyBroadcaster: FakeContract;

const avalancheChainId = 43114;

describe("Succinct Chain Adapter", function () {
  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    ({ hubPool, mockSpoke } = await hubPoolFixture());

    telepathyBroadcaster = await createFake("TelepathyBroadcasterMock");

    succinctAdapter = await (
      await getContractFactory("Succinct_Adapter", owner)
    ).deploy(telepathyBroadcaster.address, avalancheChainId);

    await hubPool.setCrossChainContracts(avalancheChainId, succinctAdapter.address, mockSpoke.address);
  });

  it("relayMessage calls spoke pool functions", async function () {
    const newAdmin = randomAddress();
    const functionCallData = mockSpoke.interface.encodeFunctionData("setCrossDomainAdmin", [newAdmin]);

    telepathyBroadcaster.send.returns("0x0000000000000000000000000000000000000000000000000000000000000001");

    await expect(hubPool.relaySpokePoolAdminFunction(avalancheChainId, functionCallData))
      .to.emit(succinctAdapter.attach(hubPool.address), "MessageRelayed")
      .withArgs(mockSpoke.address, functionCallData)
      .and.to.emit(succinctAdapter.attach(hubPool.address), "SuccinctMessageRelayed")
      .withArgs(
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        avalancheChainId,
        mockSpoke.address,
        functionCallData
      );

    expect(telepathyBroadcaster.send).to.have.been.calledWith(avalancheChainId, mockSpoke.address, functionCallData);
  });
});
