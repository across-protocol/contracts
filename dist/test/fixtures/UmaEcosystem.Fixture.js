"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.umaEcosystemFixture = void 0;
const utils_1 = require("../utils");
const constants_1 = require("../constants");
const common_1 = require("@uma/common");
exports.umaEcosystemFixture = utils_1.hre.deployments.createFixture(async ({ ethers }) => {
  const [signer] = await ethers.getSigners();
  // Deploy the UMA ecosystem contracts.
  const timer = await (await (0, utils_1.getContractFactory)("Timer", signer)).deploy();
  const finder = await (await (0, utils_1.getContractFactory)("Finder", signer)).deploy();
  const collateralWhitelist = await (await (0, utils_1.getContractFactory)("AddressWhitelist", signer)).deploy();
  const identifierWhitelist = await (await (0, utils_1.getContractFactory)("IdentifierWhitelist", signer)).deploy();
  const store = await (
    await (0, utils_1.getContractFactory)("Store", signer)
  ).deploy(constants_1.zeroRawValue, constants_1.zeroRawValue, timer.address);
  const mockOracle = await (
    await (0, utils_1.getContractFactory)("MockOracleAncillary", signer)
  ).deploy(finder.address, timer.address);
  // Set initial liveness to something != `refundProposalLiveness` so we can test that the custom liveness is set
  // correctly by the HubPool when making price requests.
  const optimisticOracle = await (
    await (0, utils_1.getContractFactory)("SkinnyOptimisticOracle", signer)
  ).deploy(constants_1.refundProposalLiveness * 10, finder.address, timer.address);
  // Set all the contracts within the finder.
  await finder.changeImplementationAddress(
    (0, utils_1.utf8ToHex)(common_1.interfaceName.CollateralWhitelist),
    collateralWhitelist.address
  );
  await finder.changeImplementationAddress(
    (0, utils_1.utf8ToHex)(common_1.interfaceName.IdentifierWhitelist),
    identifierWhitelist.address
  );
  await finder.changeImplementationAddress((0, utils_1.utf8ToHex)(common_1.interfaceName.Store), store.address);
  await finder.changeImplementationAddress(
    (0, utils_1.utf8ToHex)(common_1.interfaceName.SkinnyOptimisticOracle),
    optimisticOracle.address
  );
  await finder.changeImplementationAddress((0, utils_1.utf8ToHex)(common_1.interfaceName.Oracle), mockOracle.address);
  // Set up other required UMA ecosystem components.
  await identifierWhitelist.addSupportedIdentifier(constants_1.identifier);
  return { timer, finder, collateralWhitelist, identifierWhitelist, store, optimisticOracle };
});
module.exports.tags = ["UmaEcosystem"];
