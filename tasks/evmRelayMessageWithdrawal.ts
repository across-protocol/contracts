import { getNodeUrl, EMPTY_MERKLE_ROOT } from "@uma/common";
import { TOKEN_SYMBOLS_MAP, CHAIN_IDs } from "@across-protocol/constants";
import { task } from "hardhat/config";
import { minimalSpokePoolInterface, minimalAdapterInterface } from "./utils";
import { Event, Wallet, providers, Contract, ethers, bnZero } from "ethers";

/**
 * ```
 * yarn hardhat evm-relay-message-withdrawal \
 * --network [l2_network] --adapter [adapter_address] --spokePool [spoke_pool_address] --value [eth_to_send]
 * ```
 * This REQUIRES a spoke pool to be deployed to the specified network AND for the
 * spoke pool to have the signer as the `crossDomainAdmin`.
 */

task("evm-relay-message-withdrawal", "Test L1 <-> L2 communication between a deployed L1 adapter and a L2 spoke pool.")
  .addParam("spokePool", "address of the L2 spoke pool to use.")
  .addParam(
    "adapter",
    "address of the adapter to use. This must correspond to the network on which the L2 spoke pool is deployed"
  )
  .addParam("l2Token", "The l2 token address to withdraw from the spoke pool.")
  .addParam("amountToReturn", "amount of token to withdraw from the spoke pool.")
  .addOptionalParam(
    "value",
    "amount of ETH to send with transaction (which may be needed to call `relayMessage`, such as with zksync). This should only be used in special cases since improper use could nuke funds."
  )
  .setAction(async function (taskArguments, hre_) {
    const hre = hre_ as any;
    const msgValue = ethers.utils.parseEther(taskArguments.value === undefined ? "0" : value);
    if (!ethers.utils.isAddress(taskArguments.l2Token))
      throw new Error(`${taskArguments.l2token} is not a valid evm token address`);
    if (isNaN(taskArguments.amountToReturn) || taskArguments.amountToReturn < 0)
      throw new Error(`${taskArguments.amountToReturn} is not a valid amount to send`);

    /**
     * Setup: Need to obtain all contract addresses involved and instantiate L1/L2 providers and contracts.
     */

    // Instantiate providers/signers/chainIds
    const l2ChainId = parseInt(await hre.getChainId());
    const l1ChainId = parseInt(await hre.companionNetworks.l1.getChainId());

    const l2ProviderUrl = hre.network.config.url;

    const l1Network = l1ChainId === CHAIN_IDs.MAINNET ? "mainnet" : "sepolia";
    const l1ProviderUrl = hre.config.networks[`${l1Network}`].url;

    const l2Provider = new ethers.providers.JsonRpcProvider(l2ProviderUrl);
    const l2Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l2Provider);
    const l1Provider = new ethers.providers.JsonRpcProvider(l1ProviderUrl);
    const l1Signer = ethers.Wallet.fromMnemonic((hre.network.config.accounts as any).mnemonic).connect(l1Provider);

    // Construct the contracts
    const spokePool = new Contract(taskArguments.spokePool, minimalSpokePoolInterface, l2Signer);
    const adapter = new Contract(taskArguments.adapter, minimalAdapterInterface, l1Signer);

    console.log("[+] Successfully constructed all contracts. Determining root bundle Id to use.");
    let rootBundleId = 0;
    try {
      while (1) {
        await spokePool.rootBundles(rootBundleId);
        rootBundleId++;
      }
    } catch (e) {
      console.log(`[+] Obtained latest root bundle Id ${rootBundleId}`);
    }

    /**
     * Step 1: Craft and send a message to be sent to the provided L1 chain adapter contract. This message should be used to call `relayRootBundle` on the
     * associated L2 contract
     */

    const rootBundleType = "tuple(uint256,uint256,uint256[],uint32,address,address[])";
    // Construct the root bundle
    const encodedRootBundle = ethers.utils.defaultAbiCoder.encode(
      [rootBundleType],
      [[taskArguments.amountToReturn, l2ChainId, [], 0, taskArguments.l2Token, []]]
    );
    const rootBundleHash = ethers.utils.keccak256(encodedRootBundle);
    // Submit the root bundle to chain.
    const relayRootBundleTxnData = spokePool.interface.encodeFunctionData("relayRootBundle", [
      rootBundleHash,
      EMPTY_MERKLE_ROOT,
    ]);
    const adapterTxn = await adapter.relayMessage(spokePool.address, relayRootBundleTxnData, { value: msgValue });
    const txn = await adapterTxn.wait();
    console.log(
      `[+] Called L1 adapter (${adapter.address}) to relay refund leaf message to mock spoke pool at ${spokePool.address}. Txn: ${txn.transactionHash}`
    );

    /**
     * Step 2: Spin until we observe the message to be executed on the L2. Time varies per chain.
     */

    console.log(
      "[i] Optimistically waiting 5 minutes for L1 message to propagate. If root bundle is not observed, will check spoke every minute thereafter."
    );
    const fiveMins = 1000 * 60 * 5;
    await delay(fiveMins);

    // We should be able to query the canonical messenger to see if our L1 message was propagated, but this requires us to instantiate a unique L2 messenger contract
    // for each new chain we make, which is not scalable. Instead, we query whether our root bundle is in the spoke pool contract, as this is generalizable and does not
    // require us to instantiate any new contract.
    while (1) {
      try {
        // Check the root bundle
        await spokePool.rootBundles(rootBundleId);
        break;
      } catch (e) {
        // No root bundle made it yet. Continue to spin
        console.log("[-] Root bundle not found on L2. Waiting another 60 seconds.");
        await delay(1000 * 60);
      }
    }
    console.log("[+] Root bundle observed on L2 spoke pool. Attempting to execute.");

    /**
     * Step 3: Call `executeRelayerRefund` on the target spoke pool to send funds back to the hub pool (or, whatever was initialized as the `hubPool` in the deploy
     * script, which is likely the dev EOA).
     */

    const executeRelayerRefundLeaf = await spokePool.executeRelayerRefundLeaf(
      rootBundleId,
      [taskArguments.amountToReturn, l2ChainId, [], 0, taskArguments.l2Token, []],
      []
    );
    const l2Txn = await executeRelayerRefundLeaf.wait();
    console.log(
      `[+] Executed root bundle with transaction hash ${l2Txn.transactionHash}. You can now test the finalizer in the relayer repository.`
    );
  });

// Sleep
function delay(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
