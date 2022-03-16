import { SignerWithAddress, getContractFactory, BigNumber, toBN, Contract, randomAddress } from "../utils";
import { TokenRolesEnum } from "@uma/common";
import * as consts from "../constants";
import { getDepositParams, getRelayHash, getFillRelayParams, enableRoutes } from "../fixtures/SpokePool.Fixture";

export async function deployErc20(signer: SignerWithAddress, tokenName: string, tokenSymbol: string) {
  const erc20 = await (await getContractFactory("ExpandedERC20", signer)).deploy(tokenName, tokenSymbol, 18);
  await erc20.addMember(TokenRolesEnum.MINTER, signer.address);
  return erc20;
}

export function constructDepositParams(
  depositor: string,
  depositTokenAddress: string,
  quoteTime: BigNumber,
  depositAmount: BigNumber
) {
  return getDepositParams(depositor, depositTokenAddress, depositAmount, 1, toBN("0"), quoteTime);
}
export async function sendDeposit(
  _spokePool: Contract,
  _depositor: SignerWithAddress,
  tokenAddress: string,
  depositAmount: BigNumber
) {
  const currentSpokePoolTime = await _spokePool.getCurrentTime();
  return await _spokePool
    .connect(_depositor)
    .deposit(...constructDepositParams(_depositor.address, tokenAddress, currentSpokePoolTime, depositAmount));
}
export function constructRelayParams(
  depositor: string,
  recipient: string,
  relayTokenAddress: string,
  depositId: number,
  relayAmount: BigNumber
) {
  const { relayData } = getRelayHash(depositor, recipient, depositId, 1, consts.destinationChainId, relayTokenAddress);
  return getFillRelayParams(relayData, relayAmount);
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
      destinationToken: randomAddress(),
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
