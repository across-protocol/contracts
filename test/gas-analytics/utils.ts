import { SignerWithAddress, getContractFactory, BigNumber, toBN, Contract } from "../../utils/utils";
import * as consts from "../constants";
import { getDepositParams, getRelayHash, getFillRelayParams, enableRoutes } from "../fixtures/SpokePool.Fixture";

export async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(consts.TokenRolesEnum.MINTER, signer.address);
  return erc20;
}

export async function sendDeposit(
  spokePool: Contract,
  depositor: SignerWithAddress,
  originToken: string,
  amount: BigNumber,
  maxCount?: BigNumber
) {
  const quoteTimestamp = (await spokePool.getCurrentTime()).toNumber();
  return await spokePool.connect(depositor).deposit(
    ...getDepositParams({
      recipient: depositor.address,
      originToken,
      destinationChainId: 1,
      amount,
      relayerFeePct: toBN("0"),
      quoteTimestamp,
      maxCount,
    })
  );
}
export function constructRelayParams(
  depositor: string,
  recipient: string,
  relayTokenAddress: string,
  depositId: number,
  relayAmount: BigNumber
) {
  const { relayData } = getRelayHash(depositor, recipient, depositId, 1, consts.destinationChainId, relayTokenAddress);
  return getFillRelayParams(
    relayData,
    relayAmount,
    relayAmount.eq(relayData.amount) ? consts.repaymentChainId : consts.destinationChainId
  );
}
export async function sendRelay(
  _spokePool: Contract,
  _relayer: SignerWithAddress,
  _depositor: string,
  _recipient: string,
  tokenAddress: string,
  relayAmount: BigNumber,
  depositId: number
) {
  return await _spokePool
    .connect(_relayer)
    .fillRelay(...constructRelayParams(_depositor, _recipient, tokenAddress, depositId, relayAmount));
}
export async function warmSpokePool(
  _spokePool: Contract,
  _depositor: SignerWithAddress,
  _recipient: SignerWithAddress,
  _currencyAddress: string,
  _depositAmount: BigNumber,
  _relayAmount: BigNumber,
  _depositId: number
) {
  await enableRoutes(_spokePool, [
    {
      originToken: _currencyAddress,
      destinationChainId: 1,
    },
  ]);
  await sendDeposit(_spokePool, _depositor, _currencyAddress, _depositAmount);
  await sendRelay(
    _spokePool,
    _depositor,
    _depositor.address,
    _recipient.address,
    _currencyAddress,
    _relayAmount,
    _depositId
  );
}
