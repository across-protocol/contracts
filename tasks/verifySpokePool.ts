import assert from "assert";
import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { getDeployedAddress } from "../src/DeploymentUtils";
import { CHAIN_IDs, MAINNET_CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils/constants";

const { MAINNET, POLYGON, SEPOLIA } = CHAIN_IDs;
const TEXT_PADDING = 36;
const CHAIN_PADDING = Object.values(MAINNET_CHAIN_IDs)
  .sort((x, y) => x - y)
  .pop()
  .toString().length;
const formatChainId = (chainId: number): string => chainId.toString().padStart(CHAIN_PADDING, " ");

task("verify-spokepool", "Verify the configuration of a deployed SpokePool")
  .addFlag("routes", "Dump deposit route history (if any)")
  .setAction(async function (args, hre: HardhatRuntimeEnvironment) {
    const { deployments, ethers, companionNetworks, getChainId, network } = hre;
    const spokeChainId = parseInt(await getChainId());
    const hubChainId = Object.values(MAINNET_CHAIN_IDs).includes(spokeChainId) ? MAINNET : SEPOLIA;

    const spokeAddress = getDeployedAddress("SpokePool", spokeChainId, true);
    const hubAddress = getDeployedAddress("HubPool", hubChainId, true);

    const provider = new ethers.providers.StaticJsonRpcProvider(network.config.url);

    // Initialize contracts. Only generic SpokePool functions are used, so Ethereum_SpokePool is OK.
    const { abi } = await deployments.get("Ethereum_SpokePool");
    const spokePool = new ethers.Contract(spokeAddress, abi, provider);

    // Log state from SpokePool
    const originChainId = await spokePool.chainId();
    console.log("SpokePool.chainId()".padEnd(TEXT_PADDING) + ": " + originChainId);
    assert(Number(originChainId) === spokeChainId, `${originChainId} != ${spokeChainId}`);

    const currentTime = await spokePool.getCurrentTime();
    const formattedTime = `${currentTime} (${new Date(Number(currentTime) * 1000).toUTCString()})`;
    console.log("SpokePool.getCurrentTime()".padEnd(TEXT_PADDING) + ": " + formattedTime);

    const quoteTimeBuffer = await spokePool.depositQuoteTimeBuffer();
    console.log("SpokePool.depositQuoteTimeBuffer()".padEnd(TEXT_PADDING) + ": " + quoteTimeBuffer);

    const fillDeadlineBuffer = await spokePool.fillDeadlineBuffer();
    console.log("SpokePool.fillDeadlineBuffer()".padEnd(TEXT_PADDING) + ": " + fillDeadlineBuffer);

    const wrappedNative = await spokePool.wrappedNativeToken();
    const wrappedNativeSymbol = spokeChainId === POLYGON ? "WMATIC" : "WETH";
    const expectedWrappedNative = TOKEN_SYMBOLS_MAP[wrappedNativeSymbol].addresses[spokeChainId];
    assert(wrappedNative === expectedWrappedNative, `wrappedNativeToken: ${wrappedNative} != ${expectedWrappedNative}`);
    console.log("SpokePool.wrappedNativeToken()".padEnd(TEXT_PADDING) + ": " + wrappedNative);

    const withdrawalRecipient = await spokePool.withdrawalRecipient();
    console.log("SpokePool.withdrawalRecipient()".padEnd(TEXT_PADDING) + ": " + withdrawalRecipient);
    assert(withdrawalRecipient === hubAddress, `withdrawalRecipient: ${withdrawalRecipient} != ${hubAddress}`);

    const admin = await spokePool.crossDomainAdmin();
    console.log("SpokePool.crossDomainAdmin()".padEnd(TEXT_PADDING) + ": " + admin);
    assert(admin === hubAddress, `${admin} != ${hubAddress}`);

    // Log EnabledDepositRoute on SpokePool to test that L1 message arrived to L2:
    const filter = spokePool.filters.EnabledDepositRoute();
    const events = await spokePool.queryFilter(filter);

    console.log("Deposit routes".padEnd(TEXT_PADDING) + ": " + events.length);
    if (events.length > 0 && args.routes) {
      console.log(`\nDeposit routes:`);
      events.reverse().forEach(({ args, blockNumber, transactionHash }) => {
        const dstChainId = formatChainId(args.destinationChainId);
        const enabled = args.enabled.toString().padStart(5);
        console.log(`${blockNumber} ${args.originToken} -> ${dstChainId} ${enabled} (${transactionHash})`);
      });
    }
  });
