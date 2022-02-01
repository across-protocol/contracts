import { expect } from "chai";
import { merkleLibFixture } from "./MerkleLib.Fixture";
import { Contract, BigNumber } from "ethers";

describe("MerkleLib Claims", async function () {
  let merkleLibTest: Contract;
  beforeEach(async function () {
    ({ merkleLibTest } = await merkleLibFixture());
  });
  it("Set and read single claim", async function () {
    await merkleLibTest.setClaimed(1500);
    expect(await merkleLibTest.isClaimed(1500)).to.equal(true);

    // Make sure the correct bit is set.
    expect(await merkleLibTest.claimedBitMap(5)).to.equal(BigNumber.from(2).pow(220));
  });
  it("Set and read multiple claims", async function () {
    await merkleLibTest.setClaimed(1499);
    await merkleLibTest.setClaimed(1500);
    await merkleLibTest.setClaimed(1501);
    expect(await merkleLibTest.isClaimed(1499)).to.equal(true);
    expect(await merkleLibTest.isClaimed(1500)).to.equal(true);
    expect(await merkleLibTest.isClaimed(1501)).to.equal(true);
    const claim1499 = BigNumber.from(2).pow(219);
    const claim1500 = BigNumber.from(2).pow(220);
    const claim1501 = BigNumber.from(2).pow(221);
    expect(await merkleLibTest.claimedBitMap(5)).to.equal(claim1499.add(claim1500).add(claim1501));
  });
});
