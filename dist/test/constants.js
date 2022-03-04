"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.sampleL2GasPrice =
  exports.sampleL2MaxSubmissionCost =
  exports.sampleL2Gas =
  exports.mockTreeRoot =
  exports.amountToReturn =
  exports.amountHeldByPool =
  exports.mockSlowRelayRoot =
  exports.mockRelayerRefundRoot =
  exports.mockPoolRebalanceRoot =
  exports.mockPoolRebalanceLeafCount =
  exports.mockBundleEvaluationBlockNumbers =
  exports.zeroRawValue =
  exports.identifier =
  exports.zeroBytes32 =
  exports.zeroAddress =
  exports.refundProposalLiveness =
  exports.totalBond =
  exports.finalFeeUsdc =
  exports.finalFee =
  exports.bondAmount =
  exports.depositQuoteTimeBuffer =
  exports.firstDepositId =
  exports.repaymentChainId =
  exports.originChainId =
  exports.destinationChainId =
  exports.amountToRelayPreModifiedFees =
  exports.amountToRelayPreFees =
  exports.totalPostModifiedFeesPct =
  exports.totalPostFeesPct =
  exports.oneHundredPct =
  exports.realizedLpFeePct =
  exports.incorrectModifiedRelayerFeePct =
  exports.modifiedRelayerFeePct =
  exports.depositRelayerFeePct =
  exports.amountToRelay =
  exports.amountToDeposit =
  exports.amountToLp =
  exports.amountToSeedWallets =
    void 0;
const utils_1 = require("./utils");
exports.amountToSeedWallets = (0, utils_1.toWei)("1500");
exports.amountToLp = (0, utils_1.toWei)("1000");
exports.amountToDeposit = (0, utils_1.toWei)("100");
exports.amountToRelay = (0, utils_1.toWei)("25");
exports.depositRelayerFeePct = (0, utils_1.toWei)("0.1");
exports.modifiedRelayerFeePct = (0, utils_1.toBN)(exports.depositRelayerFeePct).add(
  (0, utils_1.toBN)((0, utils_1.toWei)("0.1"))
);
exports.incorrectModifiedRelayerFeePct = (0, utils_1.toBN)(exports.modifiedRelayerFeePct).add(
  (0, utils_1.toBN)((0, utils_1.toWei)("0.01"))
);
exports.realizedLpFeePct = (0, utils_1.toWei)("0.1");
exports.oneHundredPct = (0, utils_1.toWei)("1");
exports.totalPostFeesPct = (0, utils_1.toBN)(exports.oneHundredPct).sub(
  (0, utils_1.toBN)(exports.depositRelayerFeePct).add(exports.realizedLpFeePct)
);
exports.totalPostModifiedFeesPct = (0, utils_1.toBN)(exports.oneHundredPct).sub(
  (0, utils_1.toBN)(exports.modifiedRelayerFeePct).add(exports.realizedLpFeePct)
);
exports.amountToRelayPreFees = (0, utils_1.toBN)(exports.amountToRelay)
  .mul((0, utils_1.toBN)(exports.oneHundredPct))
  .div(exports.totalPostFeesPct);
exports.amountToRelayPreModifiedFees = (0, utils_1.toBN)(exports.amountToRelay)
  .mul((0, utils_1.toBN)(exports.oneHundredPct))
  .div(exports.totalPostModifiedFeesPct);
exports.destinationChainId = 1337;
exports.originChainId = 666;
exports.repaymentChainId = 777;
exports.firstDepositId = 0;
exports.depositQuoteTimeBuffer = 10 * 60; // 10 minutes
exports.bondAmount = (0, utils_1.toWei)("5");
exports.finalFee = (0, utils_1.toWei)("1");
exports.finalFeeUsdc = utils_1.ethers.utils.parseUnits("1", 6);
exports.totalBond = exports.bondAmount.add(exports.finalFee);
exports.refundProposalLiveness = 7200;
exports.zeroAddress = "0x0000000000000000000000000000000000000000";
exports.zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";
exports.identifier = (0, utils_1.utf8ToHex)("IS_ACROSS_V2_BUNDLE_VALID");
exports.zeroRawValue = { rawValue: "0" };
exports.mockBundleEvaluationBlockNumbers = [1, 2, 3];
exports.mockPoolRebalanceLeafCount = 5;
exports.mockPoolRebalanceRoot = (0, utils_1.createRandomBytes32)();
exports.mockRelayerRefundRoot = (0, utils_1.createRandomBytes32)();
exports.mockSlowRelayRoot = (0, utils_1.createRandomBytes32)();
// Amount of tokens to seed SpokePool with at beginning of relayer refund distribution tests
exports.amountHeldByPool = exports.amountToRelay.mul(4);
// Amount of tokens to bridge back to L1 from SpokePool in relayer refund distribution tests
exports.amountToReturn = (0, utils_1.toWei)("1");
exports.mockTreeRoot = (0, utils_1.createRandomBytes32)();
exports.sampleL2Gas = 5000000;
exports.sampleL2MaxSubmissionCost = (0, utils_1.toWei)("0.1");
exports.sampleL2GasPrice = 10e9; // 10 gWei
