import { toWei, utf8ToHex, toBN, createRandomBytes32 } from "./utils";

export const amountToSeedWallets = toWei("1500");

export const amountToLp = toWei("1000");

export const amountToDeposit = toWei("100");

export const amountToRelay = toWei("25");

export const depositRelayerFeePct = toWei("0.1");

export const realizedLpFeePct = toWei("0.1");

export const oneHundredPct = toWei("1");

export const totalPostFeesPct = toBN(oneHundredPct).sub(toBN(depositRelayerFeePct).add(realizedLpFeePct));

export const amountToRelayPreFees = toBN(amountToRelay).mul(toBN(oneHundredPct)).div(totalPostFeesPct);

export const destinationChainId = 1337;

export const originChainId = 666;

export const repaymentChainId = 777;

export const firstDepositId = 0;

export const depositQuoteTimeBuffer = 10 * 60; // 10 minutes

export const bondAmount = toWei("5");

export const finalFee = toWei("1");

export const refundProposalLiveness = 100;

export const zeroAddress = "0x0000000000000000000000000000000000000000";

export const zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

export const identifier = utf8ToHex("IS_ACROSS_V2_BUNDLE_VALID");

export const zeroRawValue = { rawValue: "0" };

export const mockBundleEvaluationBlockNumbers = [1, 2, 3];

export const mockPoolRebalanceLeafCount = 5;

export const mockPoolRebalanceRoot = createRandomBytes32();

export const mockDestinationDistributionRoot = createRandomBytes32();
