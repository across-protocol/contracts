"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const MerkleLib_Fixture_1 = require("./fixtures/MerkleLib.Fixture");
const utils_1 = require("./utils");
let merkleLibTest;
describe("MerkleLib Claims", async function () {
  beforeEach(async function () {
    ({ merkleLibTest } = await (0, MerkleLib_Fixture_1.merkleLibFixture)());
  });
  it("2D: Set and read single claim", async function () {
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1500)).to.equal(false);
    await merkleLibTest.setClaimed(1500);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1500)).to.equal(true);
    // Make sure the correct bit is set.
    (0, utils_1.expect)(await merkleLibTest.claimedBitMap(5)).to.equal(utils_1.BigNumber.from(2).pow(220));
  });
  it("2D: Set and read multiple claims", async function () {
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1499)).to.equal(false);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1500)).to.equal(false);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1501)).to.equal(false);
    await merkleLibTest.setClaimed(1499);
    await merkleLibTest.setClaimed(1500);
    await merkleLibTest.setClaimed(1501);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1499)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1500)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1501)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed(1502)).to.equal(false); // Was not set.
    const claim1499 = utils_1.BigNumber.from(2).pow(219);
    const claim1500 = utils_1.BigNumber.from(2).pow(220);
    const claim1501 = utils_1.BigNumber.from(2).pow(221);
    (0, utils_1.expect)(await merkleLibTest.claimedBitMap(5)).to.equal(claim1499.add(claim1500).add(claim1501));
  });
  it("1D: Set and read single claim", async function () {
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(false);
    await merkleLibTest.setClaimed1D(150);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.claimedBitMap1D()).to.equal(utils_1.BigNumber.from(2).pow(150));
  });
  it("1D: Set and read single claim", async function () {
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(149)).to.equal(false);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(false);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(151)).to.equal(false);
    await merkleLibTest.setClaimed1D(149);
    await merkleLibTest.setClaimed1D(150);
    await merkleLibTest.setClaimed1D(151);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(149)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(151)).to.equal(true);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(152)).to.equal(false); // Was not set.
    const claim149 = utils_1.BigNumber.from(2).pow(149);
    const claim150 = utils_1.BigNumber.from(2).pow(150);
    const claim151 = utils_1.BigNumber.from(2).pow(151);
    (0, utils_1.expect)(await merkleLibTest.claimedBitMap1D()).to.equal(claim149.add(claim150).add(claim151));
  });
  it("1D: Overflowing max index is handled correctly", async function () {
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(false);
    await merkleLibTest.setClaimed1D(150);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(150)).to.equal(true);
    // Setting right at the max should revert.
    await (0, utils_1.expect)(merkleLibTest.setClaimed1D(256)).to.be.reverted;
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(255)).to.equal(false);
    // Should be able to set right below the max.
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(255)).to.equal(false);
    await merkleLibTest.setClaimed1D(255);
    (0, utils_1.expect)(await merkleLibTest.isClaimed1D(255)).to.equal(true);
  });
});
