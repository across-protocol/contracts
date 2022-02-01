import { toWei, utf8ToHex } from "./utils";

export const amountToSeedWallets = toWei(1500);

export const amountToLp = toWei(1000);

export const amountToDeposit = toWei(100);

export const depositDestinationChainId = 10;

export const depositRelayerFeePct = toWei("0.25");

export const depositQuoteTimeBuffer = 10 * 60; // 10 minutes

export const bondAmount = toWei("5");

export const finalFee = toWei("1");

export const refundProposalLiveness = 100;

export const zeroAddress = "0x0000000000000000000000000000000000000000";

export const zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

export const identifier = utf8ToHex("IS_ACROSS_V2_RELAY_VALID");

export const zeroRawValue = { rawValue: "0" };
