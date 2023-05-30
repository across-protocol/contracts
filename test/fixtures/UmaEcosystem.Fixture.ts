import { getContractFactory, utf8ToHex, Contract } from "../../utils/utils";
import { hre } from "../../utils/utils.hre";
import { refundProposalLiveness, zeroRawValue, identifier } from "../constants";
import { interfaceName } from "@uma/common";

export const umaEcosystemFixture: () => Promise<{
  timer: Contract;
  finder: Contract;
  collateralWhitelist: Contract;
  identifierWhitelist: Contract;
  store: Contract;
  optimisticOracle: Contract;
  mockOracle: Contract;
}> = hre.deployments.createFixture(async ({ ethers }) => {
  const [signer] = await ethers.getSigners();

  // Deploy the UMA ecosystem contracts.
  const timer = await (await getContractFactory("Timer", signer)).deploy();
  const finder = await (await getContractFactory("Finder", signer)).deploy();
  const collateralWhitelist = await (await getContractFactory("AddressWhitelist", signer)).deploy();
  const identifierWhitelist = await (await getContractFactory("IdentifierWhitelist", signer)).deploy();
  const store = await (await getContractFactory("Store", signer)).deploy(zeroRawValue, zeroRawValue, timer.address);
  const mockOracle = await (
    await getContractFactory("MockOracleAncillary", signer)
  ).deploy(finder.address, timer.address);

  // Set initial liveness to something != `refundProposalLiveness` so we can test that the custom liveness is set
  // correctly by the HubPool when making price requests.
  const optimisticOracle = await (
    await getContractFactory("SkinnyOptimisticOracle", signer)
  ).deploy(refundProposalLiveness * 10, finder.address, timer.address);

  // Set all the contracts within the finder.
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.CollateralWhitelist), collateralWhitelist.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.IdentifierWhitelist), identifierWhitelist.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.Store), store.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.SkinnyOptimisticOracle), optimisticOracle.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.Oracle), mockOracle.address);

  // Set up other required UMA ecosystem components.
  await identifierWhitelist.addSupportedIdentifier(identifier);

  return { timer, finder, collateralWhitelist, identifierWhitelist, store, optimisticOracle, mockOracle };
});

module.exports.tags = ["UmaEcosystem"];
