import { toWei } from "./utils";

export const amountToSeedWallets = toWei(1500);

export const amountToLp = toWei(1000);

export const amountToDeposit = toWei(100);

export const depositDestinationChainId = 10;

export const depositRelayerFeePct = toWei("0.25");

export const depositQuoteTimeBuffer = 10 * 60; // 10 minutes

export const bondAmount = toWei("5"); // 5 ETH as the bond for proposing refund bundles.

export const refundProposalLiveness = 100;
