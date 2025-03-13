import assert from "assert";
import { getMnemonic } from "@uma/common";
import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils/constants";
import { askYesNoQuestion, resolveTokenOnChain } from "./utils";

// Chain adapter names are not 1:1 consistent with chain names, so some overrides are needed.
const chains = {
  [CHAIN_IDs.ARBITRUM]: "Arbitrum_Adapter",
  [CHAIN_IDs.ALEPH_ZERO]: "Arbitrum_CustomGasToken_Adapter",
  [CHAIN_IDs.WORLD_CHAIN]: "WorldChain_Adapter",
  [CHAIN_IDs.ZK_SYNC]: "ZkSync_Adapter",
};

task("testChainAdapter", "Verify a chain adapter")
  .addParam("chain", "chain ID of the adapter being tested")
  .addParam("token", "Token to bridge to the destination chain")
  .addParam("amount", "Amount to bridge to the destination chain")
  .setAction(async function (args, hre: HardhatRuntimeEnvironment) {
    const { deployments, ethers, getChainId, network } = hre;
    const provider = new ethers.providers.StaticJsonRpcProvider(network.config.url);
    const signer = new ethers.Wallet.fromMnemonic(getMnemonic()).connect(provider);

    const hubChainId = await getChainId();
    const spokeChainId = parseInt(args.chain);

    const [spokeName] = Object.entries(CHAIN_IDs).find(([, chainId]) => chainId === spokeChainId) ?? [];
    assert(spokeName, `Could not find any chain entry for chainId ${spokeChainId}.`);
    const adapterName =
      chains[spokeChainId] ?? `${spokeName[0].toUpperCase()}${spokeName.slice(1).toLowerCase()}_Adapter`;

    const { address: adapterAddress, abi: adapterAbi } = await deployments.get(adapterName);
    const adapter = new ethers.Contract(adapterAddress, adapterAbi, provider);
    const tokenSymbol = args.token.toUpperCase();
    const tokenAddress = TOKEN_SYMBOLS_MAP[tokenSymbol].addresses[hubChainId];

    // For USDC this will resolve to native USDC on CCTP-enabled chains.
    const _l2Token = resolveTokenOnChain(tokenSymbol, spokeChainId);
    assert(_l2Token !== undefined, `Token ${tokenSymbol} is not known on chain ${spokeChainId}`);
    const l2Token = _l2Token.address;
    console.log(`Resolved ${tokenSymbol} l2 token address on chain ${spokeChainId}: ${l2Token}.`);

    const erc20 = (await ethers.getContractFactory("ExpandedERC20")).attach(tokenAddress);
    let balance = await erc20.balanceOf(adapterAddress);
    const decimals = await erc20.decimals();
    const { amount } = args;
    const scaledAmount = ethers.utils.parseUnits(amount, decimals);

    if (balance.lt(amount)) {
      const proceed = await askYesNoQuestion(
        `\t\nWARNING: ${amount} ${tokenSymbol} may be lost.\n` +
          `\t\nProceed to send ${amount} ${tokenSymbol} to chain adapter ${adapterAddress} ?`
      );
      if (!proceed) process.exit(0);

      const txn = await erc20.connect(signer).transfer(adapterAddress, scaledAmount);
      console.log(`Transferring ${amount} ${tokenSymbol} -> ${adapterAddress}: ${txn.hash}`);
      await txn.wait();
    }

    balance = await erc20.balanceOf(adapterAddress);
    const recipient = await signer.getAddress();

    let populatedTxn = await adapter.populateTransaction.relayTokens(tokenAddress, l2Token, balance, recipient);
    const gasLimit = await provider.estimateGas(populatedTxn);

    // Any adapter requiring msg.value > 0 (i.e. Scroll) will fail here.
    const txn = await adapter.connect(signer).relayTokens(
      tokenAddress,
      l2Token,
      balance,
      recipient,
      { gasLimit: gasLimit.mul(2) } // 2x the gas limit; this helps on OP stack bridges.
    );

    console.log(
      `Relaying ${balance} ${tokenSymbol} from ${adapterAddress}` +
        ` to chain ${spokeChainId} recipient ${recipient}: ${txn.hash}.`
    );
    await txn.wait();
  });
