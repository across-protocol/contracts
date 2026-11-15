import { expect } from "chai";
import { DEPLOYMENTS, getDeployedBlockNumber } from "../src/DeploymentUtils";

describe("getDeployedBlockNumber", () => {
  it("returns the deployment block number for a known contract and network", () => {
    expect(getDeployedBlockNumber("HubPool", 1)).to.equal(14819537);
  });

  it("throws when the contract is not deployed on a known network", () => {
    expect(() => getDeployedBlockNumber("NotAContract", 1)).to.throw(
      "Contract NotAContract not found on 1 in deployed-addresses.json"
    );
  });

  it("throws when the network has no deployment records", () => {
    expect(() => getDeployedBlockNumber("HubPool", 999999)).to.throw(
      "Contract HubPool not found on 999999 in deployed-addresses.json"
    );
  });

  it("returns zero when the deployment block number is zero", () => {
    const deployment = DEPLOYMENTS["1"].contracts.HubPool;
    const originalBlockNumber = deployment.block_number;
    try {
      deployment.block_number = 0;
      expect(getDeployedBlockNumber("HubPool", 1)).to.equal(0);
    } finally {
      deployment.block_number = originalBlockNumber;
    }
  });
});
