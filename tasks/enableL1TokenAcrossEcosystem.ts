import { task, types } from "hardhat/config";
import assert from "assert";
import { CHAIN_IDs, MAINNET_CHAIN_IDs, TESTNET_CHAIN_IDs, TOKEN_SYMBOLS_MAP } from "../utils/constants";
import { askYesNoQuestion, resolveTokenOnChain, isTokenSymbol, minimalSpokePoolInterface } from "./utils";
import { TokenSymbol } from "./types";

const { ARBITRUM, OPTIMISM } = CHAIN_IDs;
const NO_SYMBOL = "----";
const NO_ADDRESS = "------------------------------------------";

const IGNORED_CHAINS = [CHAIN_IDs.BOBA, CHAIN_IDs.SOLANA];
const V4_CHAINS = [CHAIN_IDs.BSC, CHAIN_IDs.LISK, CHAIN_IDs.LINEA, CHAIN_IDs.WORLD_CHAIN];

// Supported mainnet chain IDs.
const enabledChainIds = (hubChainId: number) => {
  const chainIds = hubChainId === CHAIN_IDs.MAINNET ? MAINNET_CHAIN_IDs : TESTNET_CHAIN_IDs;
  return Object.values(chainIds)
    .map(Number)
    .filter((chainId) => !IGNORED_CHAINS.includes(chainId))
    .sort((x, y) => x - y);
};

const getChainsFromList = (taskArgInput: string): number[] =>
  taskArgInput
    ?.replace(/\s/g, "")
    ?.split(",")
    ?.map((chainId: string) => Number(chainId)) || [];

task("enableToken", "Enable a provided token across the entire ecosystem of supported chains")
  .addFlag("execute", "Provide this flag if you would like to actually execute the transaction from the EOA")
  .addFlag("disable", "Set to disable deposit routes for the specified chains")
  .addParam("token", "Symbol of token to enable")
  .addOptionalParam("chains", "Comma-delimited list of chains to enable the token on. Defaults to all supported chains")
  .addOptionalParam("burn", "Amount of LP token to burn when enabling a new token", 1, types.int)
  .addOptionalParam(
    "customoptimismbridge",
    "Custom token bridge to set for optimism, for example used with SNX and DAI"
  )
  .addOptionalParam("depositroutechains", "ChainIds to enable deposit routes for exclusively. Separated by comma.")
  .setAction(async function (taskArguments, hre_) {
    const hre = hre_ as any;
    const { burn, chains, execute, token: symbol } = taskArguments;
    const enableRoute = !taskArguments.disable;

    const hubChainId = parseInt(await hre.getChainId());
    if (hubChainId === 31337) {
      throw new Error(`Defaulted to network \`hardhat\`; specify \`--network mainnet\` or \`--network sepolia\``);
    }

    const _matchedSymbol = Object.keys(TOKEN_SYMBOLS_MAP).find((_symbol) => _symbol === symbol);
    assert(isTokenSymbol(_matchedSymbol));
    const matchedSymbol = _matchedSymbol as TokenSymbol;

    const l1TokenAddr = TOKEN_SYMBOLS_MAP[matchedSymbol].addresses[hubChainId];
    assert(l1TokenAddr !== undefined, `Could not find ${symbol} in TOKEN_SYMBOLS_MAP`);

    // If deposit routes chains are provided then we'll only add routes involving these chains. This is used to add new
    // deposit routes to a new chain for an existing L1 token, so we also won't add a new LP token if this is defined.
    const depositRouteChains = getChainsFromList(taskArguments.depositroutechains);
    if (depositRouteChains.length > 0) {
      console.log(`\nOnly adding deposit routes involving chains on list ${depositRouteChains.join(", ")}`);
    }

    const hasSetConfigStore = await askYesNoQuestion(
      `\nHave you setup the ConfigStore for this token? If not then this script will exit because a rate model must be set before the first deposit is sent otherwise the bots will error out`
    );
    if (!hasSetConfigStore) process.exit(0);

    console.log(`\nRunning task to enable L1 token over entire Across ecosystem 🌉. L1 token: ${l1TokenAddr}`);
    const { deployments, ethers } = hre;
    const { AddressZero: ZERO_ADDRESS } = ethers.constants;
    const { hexlify, zeroPad } = ethers.utils;
    const [signer] = await hre.ethers.getSigners();
    const { BigNumber } = ethers;

    // Remove chainIds that are in the ignore list.
    const _enabledChainIds = enabledChainIds(hubChainId);
    let inputChains: number[] = [];
    try {
      inputChains = (chains?.split(",") ?? _enabledChainIds).map(Number);
      console.log(`\nParsed 'chains' argument:`, inputChains);
    } catch (error) {
      throw new Error(`Failed to parse 'chains' argument ${chains} as a comma-separated list of numbers.`);
    }
    if (inputChains.length === 0) inputChains = _enabledChainIds;
    else if (inputChains.some((chain) => isNaN(chain) || !Number.isInteger(chain) || chain < 0)) {
      throw new Error(`Invalid chains list: ${inputChains}`);
    }
    const chainIds = _enabledChainIds.filter((chainId) => inputChains.includes(chainId));

    console.log("\nLoading L2 companion token address for provided L1 token.");
    const tokens = Object.fromEntries(
      chainIds.map((chainId) => {
        const token = resolveTokenOnChain(matchedSymbol, chainId);
        if (token === undefined) {
          return [chainId, { symbol: NO_SYMBOL, address: NO_ADDRESS }];
        }

        const { symbol, address } = token;
        return [chainId, { symbol: symbol as string, address }];
      })
    );

    console.table(
      Object.entries(tokens).map(([_chainId, { symbol, address }]) => ({ chainId: Number(_chainId), symbol, address })),
      ["chainId", "symbol", "address"]
    );

    // Check the user is ok with the token addresses provided. If not, abort.
    if (!(await askYesNoQuestion("\nDo these token addresses match your expectations?"))) process.exit(0);

    // Construct an ethers contract to access the `interface` prop to create encoded function calls.
    const hubPoolDeployment = await deployments.get("HubPool");
    const hubPool = new ethers.Contract(hubPoolDeployment.address, hubPoolDeployment.abi, signer);
    console.log(`\nConstructing calldata to enable these tokens. Using HubPool at address: ${hubPool.address}`);

    // Construct calldata to enable these tokens.
    // nb. This implementation relies on initial callData ordering when unpacking via Object.entries().
    const callData: { [target: string]: string[] } = {};

    // If the l1 token is not yet enabled for LP, enable it.
    let { lpToken: lpTokenAddr } = await hubPool.pooledTokens(l1TokenAddr);
    if (lpTokenAddr === ZERO_ADDRESS) {
      const [lpFactoryAddr, { abi: lpFactoryABI }] = await Promise.all([
        hubPool.lpTokenFactory(),
        deployments.get("LpTokenFactory"),
      ]);
      const lpTokenFactory = new ethers.Contract(lpFactoryAddr, lpFactoryABI, signer);
      lpTokenAddr = await lpTokenFactory.callStatic.createLpToken(l1TokenAddr);
      console.log(`\nAdding calldata to enable liquidity provision on ${l1TokenAddr} (LP token ${lpTokenAddr})`);

      const erc20 = await ethers.getContractFactory("ExpandedERC20");
      const l1Token = erc20.attach(l1TokenAddr);
      const decimals = await l1Token.decimals();
      const depositAmount = BigNumber.from(burn ?? "1").mul(BigNumber.from(10).pow(decimals));
      const doBurn = await askYesNoQuestion(`\nBurn ${burn} ${symbol} (${depositAmount}) LP tokens? (RECOMMENDED!)`);

      if (doBurn) {
        callData[l1Token.address] ??= [];
        callData[l1Token.address].push(
          l1Token.interface.encodeFunctionData("approve", [hubPool.address, depositAmount])
        );
      }

      // Create LP token and seed the LP with `depositAmount` amount.
      callData[hubPool.address] ??= [];
      callData[hubPool.address].push(
        hubPool.interface.encodeFunctionData("enableL1TokenForLiquidityProvision", [l1TokenAddr])
      );
      callData[hubPool.address].push(
        hubPool.interface.encodeFunctionData("addLiquidity", [l1Token.address, depositAmount])
      );

      // For a new token, the balance of lpToken will be 1:1 with depositAmount. Burn it.
      if (doBurn) {
        callData[lpTokenAddr] ??= [];
        const burnRecipient = hexlify(zeroPad(ethers.utils.arrayify("0x01"), 20));
        callData[lpTokenAddr].push(
          erc20.attach(lpTokenAddr).interface.encodeFunctionData("transfer", [burnRecipient, depositAmount])
        );
      }
    }

    console.log("\nAdding calldata to enable routes between all chains and tokens:");
    let i = 0; // counter for logging.
    const skipped: { [originChainId: number]: number[] } = {};
    const routeChainIds = Object.keys(tokens).map(Number);
    const chainPadding = _enabledChainIds[enabledChainIds.length - 1].toString().length;
    const formatChainId = (chainId: number): string => chainId.toString().padStart(chainPadding, " ");
    routeChainIds.forEach((fromId) => {
      const formattedFromId = formatChainId(fromId);
      const { address: inputToken } = tokens[fromId];
      skipped[fromId] = [];
      routeChainIds.forEach((toId) => {
        if (
          fromId === toId ||
          V4_CHAINS.includes(fromId) ||
          [fromId, toId].some((chainId) => tokens[chainId].symbol === NO_SYMBOL)
        ) {
          return;
        }

        // If deposit route chains are defined, only add route if it involves a chain on that list
        if (
          depositRouteChains.length === 0 ||
          depositRouteChains.includes(toId) ||
          depositRouteChains.includes(fromId)
        ) {
          const n = (++i).toString().padStart(2, " ");
          console.log(`\t${n} Added route for ${inputToken} from ${formattedFromId} -> ${formatChainId(toId)}.`);
          callData[hubPool.address] ??= [];
          callData[hubPool.address].push(
            hubPool.interface.encodeFunctionData("setDepositRoute", [fromId, toId, inputToken, enableRoute])
          );
        } else {
          skipped[fromId].push(toId);
        }
      });
    });
    console.log("");

    Object.entries(skipped).forEach(([srcChainId, dstChainIds]) => {
      if (dstChainIds.length > 0) {
        const { address: inputToken } = tokens[srcChainId];
        console.log(`\tSkipped route for ${inputToken} on chains ${srcChainId} -> ${dstChainIds.join(", ")}.`);
      }
    });

    // If deposit route chains are defined then we don't want to add a new PoolRebalanceRoute
    console.log("\nAdding calldata to set the pool rebalance route for the respective destination tokens:");
    i = 0; // counter for logging.
    const rebalanceRoutesSkipped: number[] = [];
    chainIds.forEach((toId) => {
      const destinationToken = tokens[toId].address;
      if (destinationToken === NO_ADDRESS) {
        return;
      }

      // If deposit route chains are defined, only add route if it involves a chain on that list
      if (depositRouteChains.length === 0 || depositRouteChains.includes(toId)) {
        const n = (++i).toString().padStart(2, " ");
        console.log(
          `\t${n} Setting rebalance route for chain ${symbol} ${hubChainId} -> ${destinationToken} on ${toId}.`
        );
        callData[hubPool.address] ??= [];
        callData[hubPool.address].push(
          hubPool.interface.encodeFunctionData("setPoolRebalanceRoute", [toId, l1TokenAddr, destinationToken])
        );
      } else {
        rebalanceRoutesSkipped.push(toId);
      }
    });

    if (rebalanceRoutesSkipped.length > 0) {
      console.log(`\n\tSkipped pool rebalance routes ${hubChainId} -> ${rebalanceRoutesSkipped.join(", ")}.`);
    }

    // We only need to whitelist an Arbitrum token on the SpokePool if we're setting up a pool rebalance route between
    // mainnet and Arbitrum, so if deposit route chains are set then no need to do this.
    if (depositRouteChains.includes(ARBITRUM)) {
      const arbitrumToken = tokens[ARBITRUM].address;
      console.log(
        `\nAdding call data to whitelist L2 ${arbitrumToken} -> L1 token ${l1TokenAddr} on Arbitrum.` +
          " This is only needed on this chain."
      );

      // Address doesn't matter, we only want the interface.
      const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
      // Find the address of the Arbitrum representation of this token. Construct whitelistToken call to send to the
      // Arbitrum spoke pool via the relaySpokeAdminFunction call.
      const whitelistTokenCallData = spokePool.interface.encodeFunctionData("whitelistToken", [
        arbitrumToken,
        l1TokenAddr,
      ]);
      callData[hubPool.address] ??= [];
      callData[hubPool.address].push(
        hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [ARBITRUM, whitelistTokenCallData])
      );
    }

    // Add optimism setTokenBridge call if the token has a custom bridge needed to get to mainnet.
    if (depositRouteChains.includes(OPTIMISM) && taskArguments.customoptimismbridge) {
      console.log("\nAdding call data to set custom Optimism bridge.");

      // Address doesn't matter, we only want the interface:
      const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
      const optimismToken = tokens[OPTIMISM].address;
      const setTokenBridgeCallData = spokePool.interface.encodeFunctionData("setTokenBridge", [
        optimismToken,
        taskArguments.customoptimismbridge,
      ]);
      callData[hubPool.address].push(
        hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [OPTIMISM, setTokenBridgeCallData])
      );
    }

    console.log(`\n***DONE***\nProduced calldata for ${Object.values(callData).flat().length} calls.`);
    if (execute) {
      console.log(`\n--execute provided. Submitting transactions.`);
      for (let [target, calls] of Object.entries(callData)) {
        if (target === hubPool.address) {
          const { hash, wait } = await hubPool.multicall(calls);
          console.log(`\nTarget ${target}: ${hash}`);
          await wait();
          continue;
        }
        for (const data of calls) {
          const txnRequest = await signer.populateTransaction({ to: target, data });
          const txn = await signer.signTransaction(txnRequest);
          const { hash, wait } = await signer.sendTransaction(txn);
          console.log(`\nTarget ${target}: ${hash}`);
          await wait();
        }
      }
    } else {
      let i = 1;
      for (const [target, calldata] of Object.entries(callData)) {
        console.log(`\nTransaction ${i++}:`);
        if (target === hubPool.address) {
          console.log("\tmethod: multicall");
          console.log(`\ttarget: ${target}\n\tdata:\t${[calldata]}`);
          continue;
        }

        calldata.forEach((data) => console.log(`\ttarget:\t${target}\n\tdata:\t${data}`));
      }
    }
  });
