import { toWei, toBN } from "./utils";

export const amountToSeedWallets = toWei("1500");

export const amountToLp = toWei("1000");

export const amountToDeposit = toWei("100");

export const amountToRelay = toWei("50");

export const depositDestinationChainId = 10;

export const depositRelayerFeePct = toWei("0.25");

export const realizedLpFeePct = toWei("0.25")

export const oneHundredPct = toWei("1")

export const totalFeesPct = toBN(depositRelayerFeePct).add(realizedLpFeePct)

export const amountToRelayNetFees = toBN(amountToRelay).mul(totalFeesPct).div(toBN(oneHundredPct))

export const depositQuoteTimeBuffer = 10 * 60; // 10 minutes
