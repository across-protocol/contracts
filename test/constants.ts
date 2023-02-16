import { toWei, utf8ToHex, toBN, createRandomBytes32 } from "./utils";

import { ethers } from "ethers";

export { TokenRolesEnum } from "@uma/common";

export const maxUint256 = ethers.constants.MaxInt256;

export const amountToSeedWallets = toWei("1500");

export const amountToLp = toWei("1000");

export const amountToDeposit = toWei("100");

export const amountToRelay = toWei("25");

export const depositRelayerFeePct = toWei("0.1");

export const modifiedRelayerFeePct = toBN(depositRelayerFeePct).add(toBN(toWei("0.1")));

export const incorrectModifiedRelayerFeePct = toBN(modifiedRelayerFeePct).add(toBN(toWei("0.01")));

export const realizedLpFeePct = toWei("0.1");

export const oneHundredPct = toWei("1");

export const totalPostFeesPct = toBN(oneHundredPct).sub(toBN(depositRelayerFeePct).add(realizedLpFeePct));

export const totalPostModifiedFeesPct = toBN(oneHundredPct).sub(toBN(modifiedRelayerFeePct).add(realizedLpFeePct));

export const amountToRelayPreFees = toBN(amountToRelay).mul(toBN(oneHundredPct)).div(totalPostFeesPct);

export const amountToRelayPreModifiedFees = toBN(amountToRelay).mul(toBN(oneHundredPct)).div(totalPostModifiedFeesPct);

export const amountToRelayPreLPFee = amountToRelayPreFees.mul(oneHundredPct.sub(realizedLpFeePct)).div(oneHundredPct);

export const destinationChainId = 1337; // Should be equal to MockSpokePool.chainId() return value.

export const originChainId = 666;

export const repaymentChainId = 777;

export const firstDepositId = 0;

export const depositQuoteTimeBuffer = 60 * 60; // 60 minutes

export const bondAmount = toWei("5");

export const finalFee = toWei("1");

export const finalFeeUsdc = ethers.utils.parseUnits("1", 6);

export const totalBond = bondAmount.add(finalFee);

export const refundProposalLiveness = 7200;

export const zeroAddress = "0x0000000000000000000000000000000000000000";

export const zeroBytes32 = "0x0000000000000000000000000000000000000000000000000000000000000000";

export const identifier = utf8ToHex("ACROSS-V2");

export const zeroRawValue = { rawValue: "0" };

export const mockBundleEvaluationBlockNumbers = [1, 2, 3];

export const mockPoolRebalanceLeafCount = 5;

export const mockPoolRebalanceRoot = createRandomBytes32();

export const mockRelayerRefundRoot = createRandomBytes32();

export const mockSlowRelayRoot = createRandomBytes32();

// Amount of tokens to seed SpokePool with at beginning of relayer refund distribution tests
export const amountHeldByPool = amountToRelay.mul(4);

// Amount of tokens to bridge back to L1 from SpokePool in relayer refund distribution tests
export const amountToReturn = toWei("1");

export const mockTreeRoot = createRandomBytes32();

// Following should match variables set in Arbitrum_Adapter and Optimism_Adapter.
export const sampleL2Gas = 2000000;
export const sampleL2GasSendTokens = 300000;

export const sampleL2MaxSubmissionCost = toWei("0.01");

export const sampleL2GasPrice = 5e9;

// Max number of refunds in relayer refund leaf for a { repaymentChainId, L2TokenAddress }.
export const maxRefundsPerRelayerRefundLeaf = 3;

// Max number of L1 tokens for a chain ID in a pool rebalance leaf.
export const maxL1TokensPerPoolRebalanceLeaf = 3;

// Once running balances hits this number for an L1 token, net send amount should be set to running
// balances to transfer tokens to the spoke pool.
export const l1TokenTransferThreshold = toWei(100);

// DAI's Rate model.
export const sampleRateModel = {
  UBar: toWei(0.8).toString(),
  R0: toWei(0.04).toString(),
  R1: toWei(0.07).toString(),
  R2: toWei(0.75).toString(),
};
