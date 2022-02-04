import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";

import { SignerWithAddress, toBNWei, seedWallet } from "./utils";
import * as consts from "./constants";
import { hubPoolFixture, enableTokensForLP } from "./HubPool.Fixture";
import { buildPoolRebalanceTree, buildPoolRebalanceLeafs } from "./MerkleLib.utils";

let hubPool: Contract, mockAdapter: Contract, weth: Contract, mockSpoke: Contract, timer: Contract;
let owner: SignerWithAddress, dataWorker: SignerWithAddress, liquidityProvider: SignerWithAddress;
let l2Weth: string, l2Dai: string;

describe("HubPool LP fees", function () {
  beforeEach(async function () {
    [owner, dataWorker, liquidityProvider] = await ethers.getSigners();
    ({ weth, hubPool, mockAdapter, mockSpoke, timer, l2Weth, l2Dai } = await hubPoolFixture());
    await seedWallet(dataWorker, [], weth, consts.bondAmount.add(consts.finalFee).mul(2));
    await seedWallet(liquidityProvider, [], weth, consts.amountToLp.mul(10));

    await enableTokensForLP(owner, hubPool, weth, [weth]);
    await weth.connect(liquidityProvider).approve(hubPool.address, consts.amountToLp);
    await hubPool.connect(liquidityProvider).addLiquidity(weth.address, consts.amountToLp);
    await weth.connect(dataWorker).approve(hubPool.address, consts.bondAmount.mul(10));
  });

  it("Fee tracking variables are correctly updated at the execution of a refund", async function () {});
});
