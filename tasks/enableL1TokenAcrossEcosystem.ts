import { task } from "hardhat/config";
import assert from "assert";
import { askYesNoQuestion, minimalSpokePoolInterface } from "./utils";
import { TOKEN_SYMBOLS_MAP } from "../utils/constants";

const enabledChainIds = [1, 10, 137, 42161, 324, 8453, 59144, 34443]; // Supported mainnet chain IDs.

const getChainsFromList = (taskArgInput: string): number[] =>
  taskArgInput
    ?.replace(/\s/g, "")
    ?.split(",")
    ?.map((chainId: string) => Number(chainId)) || [];

task("enable-l1-token-across-ecosystem", "Enable a provided token across the entire ecosystem of supported chains")
  .addFlag("execute", "Provide this flag if you would like to actually execute the transaction from the EOA")
  .addParam("token", "Symbol of token to enable")
  .addParam("chains", "Comma-delimited list of chains to enable the token on. Defaults to all supported chains")
  .addOptionalParam(
    "customoptimismbridge",
    "Custom token bridge to set for optimism, for example used with SNX and DAI"
  )
  .addOptionalParam("depositroutechains", "ChainIds to enable deposit routes for exclusively. Separated by comma.")
  .setAction(async function (taskArguments, hre_) {
    const hre = hre_ as any;
    const matchedSymbol = Object.keys(TOKEN_SYMBOLS_MAP).find(
      (symbol) => symbol === taskArguments.token
    ) as keyof typeof TOKEN_SYMBOLS_MAP;
    assert(matchedSymbol !== undefined, `Could not find token with symbol ${taskArguments.token} in TOKEN_SYMBOLS_MAP`);
    const hubPoolChainId = await hre.getChainId();
    const l1Token = TOKEN_SYMBOLS_MAP[matchedSymbol].addresses[hubPoolChainId];

    // If deposit routes chains are provided then we'll only add routes involving these chains. This is used to add new
    // deposit routes to a new chain for an existing L1 token, so we also won't add a new LP token if this is defined.
    const depositRouteChains = getChainsFromList(taskArguments.depositroutechains);
    if (depositRouteChains.length > 0) {
      console.log(`\n0. Only adding deposit routes involving chains on list ${depositRouteChains.join(", ")}`);
    }

    const hasSetConfigStore = await askYesNoQuestion(
      `\nHave you setup the ConfigStore for this token? If not then this script will exit because a rate model must be set before the first deposit is sent otherwise the bots will error out`
    );
    if (!hasSetConfigStore) process.exit(0);

    console.log(`\n0. Running task to enable L1 token over entire Across ecosystem 🌉. L1 token: ${l1Token}`);
    const { deployments, ethers } = hre;
    const signer = (await hre.ethers.getSigners())[0];

    // Remove chainIds that are in the ignore list.
    let inputChains: number[] = [];
    try {
      const parsedChains: string[] = taskArguments.chains.split(",");
      inputChains = parsedChains.map((x) => Number(x));
      console.log(`\nParsed 'chains' argument:`, inputChains);
    } catch (error) {
      throw new Error(
        `Failed to parse 'chains' argument ${taskArguments.chains} as a comma-separated list of numbers.`
      );
    }
    if (inputChains.length === 0) inputChains = enabledChainIds;
    else if (inputChains.some((chain) => isNaN(chain) || !Number.isInteger(chain) || chain < 0)) {
      throw new Error(`Invalid chains list: ${inputChains}`);
    }
    const chainIds = enabledChainIds.filter((chainId) => inputChains.includes(chainId));

    console.log("\n1. Loading L2 companion token address for provided L1 token.");
    const tokens = await Promise.all(
      chainIds.map((chainId) => {
        // Handle USDC special case where L1 USDC is mapped to different token symbols on L2s.
        if (matchedSymbol === "USDC") {
          const nativeUsdcAddress = TOKEN_SYMBOLS_MAP.USDC.addresses[chainId];
          const bridgedUsdcAddress = TOKEN_SYMBOLS_MAP["USDC.e"].addresses[chainId];
          if (nativeUsdcAddress) {
            return nativeUsdcAddress;
          } else if (bridgedUsdcAddress) {
            return bridgedUsdcAddress;
          } else {
            throw new Error(
              `Could not find token address on chain ${chainId} in TOKEN_SYMBOLS_MAP for USDC.e or Native USDC`
            );
          }
        }
        const l2Address = TOKEN_SYMBOLS_MAP[matchedSymbol].addresses[chainId];
        if (l2Address === undefined) {
          throw new Error(`Could not find token address on chain ${chainId} in TOKEN_SYMBOLS_MAP`);
        }
        return l2Address;
      })
    );

    console.table(
      chainIds.map((chainId, index) => {
        return {
          chainId,
          address: tokens[index],
        };
      }),
      ["chainId", "address"]
    );

    // Check the user is ok with the token addresses provided. If not, abort.
    if (!(await askYesNoQuestion("\n2. Do these token addresses match your expectations?"))) process.exit(0);

    // Construct an ethers contract to access the `interface` prop to create encoded function calls.
    const hubPoolDeployment = await deployments.get("HubPool");
    const hubPool = new ethers.Contract(hubPoolDeployment.address, hubPoolDeployment.abi, signer);

    console.log("\n4. Constructing calldata to enable these tokens. Using HubPool at address:", hubPool.address);

    // Construct calldata to enable these tokens.
    const callData = [];

    // If deposit route chains are defined then we don't want to add a new LP token:
    if (depositRouteChains.length === 0) {
      console.log("\n5. Adding calldata to enable liquidity provision on", l1Token);
      callData.push(hubPool.interface.encodeFunctionData("enableL1TokenForLiquidityProvision", [l1Token]));
    }

    console.log("\n6. Adding calldata to enable routes between all chains and tokens:");
    let i = 0; // counter for logging.
    chainIds.forEach((fromId, fromIndex) => {
      chainIds.forEach((toId, _) => {
        if (fromId === toId) return;

        // If deposit route chains are defined, only add route if it involves a chain on that list
        if (
          depositRouteChains.length === 0 ||
          depositRouteChains.includes(toId) ||
          depositRouteChains.includes(fromId)
        ) {
          console.log(`\t 6.${++i}\t Adding calldata for token ${tokens[fromIndex]} for route ${fromId} -> ${toId}`);
          callData.push(
            hubPool.interface.encodeFunctionData("setDepositRoute", [fromId, toId, tokens[fromIndex], true])
          );
        } else {
          console.log(
            `\t\t Skipping route ${fromId} -> ${toId} because it doesn't involve a chain on the exclusive list`
          );
        }
      });
    });

    // If deposit route chains are defined then we don't want to add a new PoolRebalanceRoute
    if (depositRouteChains.length === 0) {
      console.log("\n7. Adding calldata to set the pool rebalance route for the respective destination tokens:");
      let j = 0; // counter for logging.
      chainIds.forEach((toId, toIndex) => {
        // If deposit route chains are defined, only add route if it involves a chain on that list
        if (depositRouteChains.length === 0 || depositRouteChains.includes(toId)) {
          console.log(`\t 7.${++j}\t Adding calldata for rebalance route for L2Token ${tokens[toIndex]} on ${toId}`);
          callData.push(
            hubPool.interface.encodeFunctionData("setPoolRebalanceRoute", [toId, l1Token, tokens[toIndex]])
          );
        } else {
          console.log(
            `\t\t Skipping pool rebalance rout -> ${toId} because it doesn't involve a chain on the exclusive list`
          );
        }
      });

      // We only need to whitelist an Arbitrum token on the SpokePool if we're setting up a pool rebalance route between
      // mainnet and Arbitrum, so if deposit route chains are set then no need to do this.
      if (chainIds.includes(42161)) {
        const arbitrumToken = tokens[chainIds.indexOf(42161)];
        console.log(
          `\n8. Adding call data to whitelist L2 ${arbitrumToken} -> L1 token ${l1Token} on Arbitrum. This is only needed on this chain`
        );

        // Address doesn't matter, we only want the interface.
        const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
        // Find the address of the the Arbitrum representation of this token. Construct whitelistToken call to send to the
        // Arbitrum spoke pool via the relaySpokeAdminFunction call.
        const whitelistTokenCallData = spokePool.interface.encodeFunctionData("whitelistToken", [
          arbitrumToken,
          l1Token,
        ]);
        callData.push(
          hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [42161, whitelistTokenCallData])
        );
      }

      // Add optimism setTokenBridge call if the token has a custom bridge needed to get to mainnet.
      if (chainIds.includes(10) && taskArguments.customoptimismbridge) {
        console.log("\n9. Adding call data to set custom Optimism bridge.");

        // Address doesn't matter, we only want the interface:
        const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
        const optimismToken = tokens[chainIds.indexOf(10)];
        const setTokenBridgeCallData = spokePool.interface.encodeFunctionData("setTokenBridge", [
          optimismToken,
          taskArguments.customoptimismbridge,
        ]);
        callData.push(
          hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [10, setTokenBridgeCallData])
        );
      }
    }

    console.log(`\n10. ***DONE.***\nCalldata to enable desired token has been constructed!`);
    console.log(
      `CallData contains ${callData.length} transactions, which can be sent in one multicall to hub pool @ ${hubPoolDeployment.address}🚀`
    );
    console.log(JSON.stringify(callData).replace(/"/g, ""));

    if (taskArguments.execute && callData.length > 0) {
      console.log(`\n10. --execute provided. Trying to execute this on mainnet.`);
      const { hash } = await hubPool.multicall(callData);
      console.log(`\nTransaction hash: ${hash}`);
    }
  });
