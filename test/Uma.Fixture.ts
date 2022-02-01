import { getContractFactory, utf8ToHex } from "./utils";
import { refundProposalLiveness, zeroRawValue, identifier } from "./constants";
import { interfaceName } from "@uma/common";

export async function deployUmaEcosystemContracts(deployer: any) {
  // Deploy the UMA ecosystem contracts.
  const timer = await (await getContractFactory("Timer", deployer)).deploy();
  const finder = await (await getContractFactory("Finder", deployer)).deploy();
  const collateralWhitelist = await (await getContractFactory("AddressWhitelist", deployer)).deploy();
  const identifierWhitelist = await (await getContractFactory("IdentifierWhitelist", deployer)).deploy();
  const store = await (await getContractFactory("Store", deployer)).deploy(zeroRawValue, zeroRawValue, timer.address);
  const mockOracle = await (
    await getContractFactory("MockOracleAncillary", deployer)
  ).deploy(finder.address, timer.address);

  // Set initial liveness to something != `refundProposalLiveness` so we can test that the custom liveness is set
  // correctly by the HubPool when making price requests.
  const optimisticOracle = await (
    await getContractFactory("SkinnyOptimisticOracle", deployer)
  ).deploy(refundProposalLiveness * 10, finder.address, timer.address);

  // Set all the contracts within the finder.
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.CollateralWhitelist), collateralWhitelist.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.IdentifierWhitelist), identifierWhitelist.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.Store), store.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.SkinnyOptimisticOracle), optimisticOracle.address);
  await finder.changeImplementationAddress(utf8ToHex(interfaceName.Oracle), mockOracle.address);

  // Set up other required UMA ecosystem components.
  await identifierWhitelist.addSupportedIdentifier(identifier);

  return { timer, finder, collateralWhitelist, identifierWhitelist, store, optimisticOracle };
}
