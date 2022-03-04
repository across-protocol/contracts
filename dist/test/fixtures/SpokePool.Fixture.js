"use strict";
var __createBinding =
  (this && this.__createBinding) ||
  (Object.create
    ? function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        Object.defineProperty(o, k2, {
          enumerable: true,
          get: function () {
            return m[k];
          },
        });
      }
    : function (o, m, k, k2) {
        if (k2 === undefined) k2 = k;
        o[k2] = m[k];
      });
var __setModuleDefault =
  (this && this.__setModuleDefault) ||
  (Object.create
    ? function (o, v) {
        Object.defineProperty(o, "default", { enumerable: true, value: v });
      }
    : function (o, v) {
        o["default"] = v;
      });
var __importStar =
  (this && this.__importStar) ||
  function (mod) {
    if (mod && mod.__esModule) return mod;
    var result = {};
    if (mod != null)
      for (var k in mod)
        if (k !== "default" && Object.prototype.hasOwnProperty.call(mod, k)) __createBinding(result, mod, k);
    __setModuleDefault(result, mod);
    return result;
  };
Object.defineProperty(exports, "__esModule", { value: true });
exports.modifyRelayHelper =
  exports.getExecuteSlowRelayParams =
  exports.getFillRelayUpdatedFeeParams =
  exports.getFillRelayParams =
  exports.getDepositParams =
  exports.getRelayHash =
  exports.deposit =
  exports.enableRoutes =
  exports.spokePoolFixture =
    void 0;
const common_1 = require("@uma/common");
const utils_1 = require("../utils");
const consts = __importStar(require("../constants"));
exports.spokePoolFixture = utils_1.hre.deployments.createFixture(async ({ ethers }) => {
  const [deployerWallet, crossChainAdmin, hubPool] = await ethers.getSigners();
  // Useful contracts.
  const timer = await (await (0, utils_1.getContractFactory)("Timer", deployerWallet)).deploy();
  // Create tokens:
  const weth = await (await (0, utils_1.getContractFactory)("WETH9", deployerWallet)).deploy();
  const erc20 = await (
    await (0, utils_1.getContractFactory)("ExpandedERC20", deployerWallet)
  ).deploy("USD Coin", "USDC", 18);
  await erc20.addMember(common_1.TokenRolesEnum.MINTER, deployerWallet.address);
  const unwhitelistedErc20 = await (
    await (0, utils_1.getContractFactory)("ExpandedERC20", deployerWallet)
  ).deploy("Unwhitelisted", "UNWHITELISTED", 18);
  await unwhitelistedErc20.addMember(common_1.TokenRolesEnum.MINTER, deployerWallet.address);
  const destErc20 = await (
    await (0, utils_1.getContractFactory)("ExpandedERC20", deployerWallet)
  ).deploy("L2 USD Coin", "L2 USDC", 18);
  await destErc20.addMember(common_1.TokenRolesEnum.MINTER, deployerWallet.address);
  // Deploy the pool
  const spokePool = await (
    await (0, utils_1.getContractFactory)("MockSpokePool", { signer: deployerWallet })
  ).deploy(crossChainAdmin.address, hubPool.address, weth.address, timer.address);
  return { timer, weth, erc20, spokePool, unwhitelistedErc20, destErc20 };
});
async function enableRoutes(spokePool, routes) {
  for (const route of routes) {
    await spokePool.setEnableRoute(
      route.originToken,
      route.destinationChainId ? route.destinationChainId : consts.destinationChainId,
      route.enabled !== undefined ? route.enabled : true
    );
  }
}
exports.enableRoutes = enableRoutes;
async function deposit(spokePool, token, recipient, depositor) {
  const currentSpokePoolTime = await spokePool.getCurrentTime();
  await spokePool
    .connect(depositor)
    .deposit(
      recipient.address,
      token.address,
      consts.amountToDeposit,
      consts.depositRelayerFeePct,
      consts.destinationChainId,
      currentSpokePoolTime
    );
}
exports.deposit = deposit;
function getRelayHash(
  _depositor,
  _recipient,
  _depositId,
  _originChainId,
  _destinationToken,
  _amount,
  _realizedLpFeePct,
  _relayerFeePct
) {
  const relayData = {
    depositor: _depositor,
    recipient: _recipient,
    destinationToken: _destinationToken,
    amount: _amount || consts.amountToDeposit.toString(),
    originChainId: _originChainId.toString(),
    realizedLpFeePct: _realizedLpFeePct || consts.realizedLpFeePct.toString(),
    relayerFeePct: _relayerFeePct || consts.depositRelayerFeePct.toString(),
    depositId: _depositId.toString(),
  };
  const relayHash = utils_1.ethers.utils.keccak256(
    utils_1.defaultAbiCoder.encode(
      ["address", "address", "address", "uint256", "uint256", "uint64", "uint64", "uint32"],
      Object.values(relayData)
    )
  );
  return {
    relayHash,
    relayData,
  };
}
exports.getRelayHash = getRelayHash;
function getDepositParams(_recipient, _originToken, _amount, _destinationChainId, _relayerFeePct, _quoteTime) {
  return [
    _recipient,
    _originToken,
    _amount.toString(),
    _destinationChainId.toString(),
    _relayerFeePct.toString(),
    _quoteTime.toString(),
  ];
}
exports.getDepositParams = getDepositParams;
function getFillRelayParams(_relayData, _maxTokensToSend, _repaymentChain) {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _relayData.destinationToken,
    _relayData.amount,
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct,
    _relayData.relayerFeePct,
    _relayData.depositId,
  ];
}
exports.getFillRelayParams = getFillRelayParams;
function getFillRelayUpdatedFeeParams(_relayData, _maxTokensToSend, _updatedFee, _signature, _repaymentChain) {
  return [
    _relayData.depositor,
    _relayData.recipient,
    _relayData.destinationToken,
    _relayData.amount,
    _maxTokensToSend.toString(),
    _repaymentChain ? _repaymentChain.toString() : consts.repaymentChainId.toString(),
    _relayData.originChainId,
    _relayData.realizedLpFeePct,
    _relayData.relayerFeePct,
    _updatedFee.toString(),
    _relayData.depositId,
    _signature,
  ];
}
exports.getFillRelayUpdatedFeeParams = getFillRelayUpdatedFeeParams;
function getExecuteSlowRelayParams(
  _depositor,
  _recipient,
  _destToken,
  _amount,
  _originChainId,
  _realizedLpFeePct,
  _relayerFeePct,
  _depositId,
  _relayerRefundId,
  _proof
) {
  return [
    _depositor,
    _recipient,
    _destToken,
    _amount.toString(),
    _originChainId.toString(),
    _realizedLpFeePct.toString(),
    _relayerFeePct.toString(),
    _depositId.toString(),
    _relayerRefundId.toString(),
    _proof,
  ];
}
exports.getExecuteSlowRelayParams = getExecuteSlowRelayParams;
async function modifyRelayHelper(modifiedRelayerFeePct, depositId, originChainId, depositor) {
  const messageHash = utils_1.ethers.utils.keccak256(
    utils_1.defaultAbiCoder.encode(
      ["string", "uint64", "uint32", "uint32"],
      ["ACROSS-V2-FEE-1.0", modifiedRelayerFeePct, depositId, originChainId]
    )
  );
  const signature = await depositor.signMessage(utils_1.ethers.utils.arrayify(messageHash));
  return {
    messageHash,
    signature,
  };
}
exports.modifyRelayHelper = modifyRelayHelper;
