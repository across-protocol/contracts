"use strict";
var __importDefault =
  (this && this.__importDefault) ||
  function (mod) {
    return mod && mod.__esModule ? mod : { default: mod };
  };
Object.defineProperty(exports, "__esModule", { value: true });
exports.merkleLibFixture = void 0;
const utils_1 = require("../utils");
const hardhat_1 = __importDefault(require("hardhat"));
exports.merkleLibFixture = hardhat_1.default.deployments.createFixture(async ({ deployments }) => {
  const [signer] = await hardhat_1.default.ethers.getSigners();
  const merkleLibTest = await (await (0, utils_1.getContractFactory)("MerkleLibTest", { signer })).deploy();
  return { merkleLibTest };
});
