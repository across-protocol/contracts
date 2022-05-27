import { task } from "hardhat/config";
import assert from "assert";
import { findL2TokenForL1Token, askYesNoQuestion, zeroAddress, minimalSpokePoolInterface } from "./utils";

const enabledChainIds = [1, 10, 137, 288, 42161]; // Supported mainnet chain IDs.

task("enable-l1-token-across-ecosystem", "Enable a provided token across the entire ecosystem of supported chains")
  .addParam("chain1token", "Address of the token to enable, as defined on L1")
  .addFlag("execute", "Provide this flag if you would like to actually execute the transaction from the EOA")
  .addOptionalParam("chain10token", "Address of the token on chainID 10. Used to override the auto detect")
  .addOptionalParam("chain137token", "Address of the token on chainID 137. Used to override the auto detect")
  .addOptionalParam("chain288token", "Address of the token on chainID 288. Used to override the auto detect")
  .addOptionalParam("chain42161token", "Address of the token on chainID 42161. Used to override the auto detect")
  .addOptionalParam("ignorechains", "ChainIds to ignore. Separated by comma.")
  .setAction(async function (taskArguments, hre_) {
    const hre = hre_ as any;
    const l1Token = taskArguments.chain1token;
    assert(l1Token, "chain1token argument must be provided");
    const ignoredChainIds: number[] =
      taskArguments.ignorechains
        ?.replace(/\s/g, "")
        ?.split(",")
        ?.map((chainId: string) => Number(chainId)) || [];
    if (ignoredChainIds.includes(1)) throw new Error("Cannot ignore chainId 1");
    console.log(`\n0. Running task to enable L1 token over entire Across ecosystem 🌉. L1 token: ${l1Token}`);
    const { deployments, ethers } = hre;
    const signer = (await hre.ethers.getSigners())[0];

    // Remove chainIds that are in the ignore list.
    let chainIds = enabledChainIds.filter((chainId) => !ignoredChainIds.includes(chainId));

    console.log("\n1. Auto detecting L2 companion token address for provided L1 token.");
    const autoDetectedTokens = await Promise.all(
      chainIds.slice(1).map((chainId) => findL2TokenForL1Token(chainId, l1Token))
    );

    let tokens: string[] = [];
    tokens[0] = l1Token;
    chainIds
      .slice(1)
      .forEach(
        (chainId, index) => (tokens[index + 1] = taskArguments[`chain${chainId}token`] ?? autoDetectedTokens[index])
      );

    for (let i = 0; i < chainIds.length; i++) {
      const chainId = chainIds[i];
      if (
        tokens[i] === zeroAddress &&
        !(await askYesNoQuestion(
          `\nNo address found for chainId: ${chainId}. Would you like to remove routes to and from this chain?`
        ))
      ) {
        console.log(`Please rerun with override address for chainId: ${chainId}`);
        process.exit(0);
      }
    }

    chainIds = chainIds.filter((chainId, index) => tokens[index] !== zeroAddress);
    tokens = tokens.filter((token) => token !== zeroAddress);

    console.table(
      chainIds.map((chainId, index) => {
        return { chainId, address: tokens[index], autoDetected: taskArguments[`chain${chainId}token`] === undefined };
      }),
      ["chainId", "address", "autoDetected"]
    );

    // Check the user is ok with the token addresses provided. If not, abort.
    if (!(await askYesNoQuestion("\n2. Do these token addresses match your expectations?"))) process.exit(0);

    // Construct an ethers contract to access the `interface` prop to create encoded function calls.
    const hubPoolDeployment = await deployments.get("HubPool");
    const hubPool = new ethers.Contract(hubPoolDeployment.address, hubPoolDeployment.abi, signer);

    console.log("\n4. Constructing calldata to enable these tokens. Using HubPool at address:", hubPool.address);

    // Construct calldata to enable these tokens.
    const callData = [];
    console.log("\n5. Adding calldata to enable liquidity provision on", l1Token);
    callData.push(hubPool.interface.encodeFunctionData("enableL1TokenForLiquidityProvision", [l1Token]));

    console.log("\n6. Adding calldata to enable routes between all chains and tokens:");
    let i = 0; // counter for logging.
    chainIds.forEach((fromId, fromIndex) => {
      chainIds.forEach((toId, toIndex) => {
        if (fromId === toId) return;

        console.log(`\t 6.${++i}\t Adding calldata for token ${tokens[fromIndex]} for route ${fromId} -> ${toId}`);
        callData.push(hubPool.interface.encodeFunctionData("setDepositRoute", [fromId, toId, tokens[fromIndex], true]));
      });
    });

    console.log("\n7. Adding calldata to set the pool rebalance route for the respective destination tokens:");
    chainIds.forEach((toId, toIndex) => {
      console.log(`\t 7.${toIndex}\t Adding calldata for rebalance route for L2Token ${tokens[toIndex]} on ${toId}`);
      callData.push(hubPool.interface.encodeFunctionData("setPoolRebalanceRoute", [toId, l1Token, tokens[toIndex]]));
    });

    if (chainIds.includes(42161)) {
      console.log("\n8. Adding call data to whitelist L1 token on Arbitrum. This is only needed on this chain");

      const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
      // Find the address of the the Arbitrum representation of this token. Construct whitelistToken call to send to the
      // Arbitrum spoke pool via the relaySpokeAdminFunction call.
      const arbitrumToken = tokens[chainIds.indexOf(42161)];
      const whitelistTokenCallData = spokePool.interface.encodeFunctionData("whitelistToken", [arbitrumToken, l1Token]);
      callData.push(
        hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [42161, whitelistTokenCallData])
      );
    }

    // Add optimism setTokenBridge call

    console.log(`\n9. ***DONE.***\nCalldata to enable desired token has been constructed!`);
    console.log(`CallData contains ${callData.length} transactions, which can be sent in one multicall🚀`);
    console.log(JSON.stringify(callData).replace(/"/g, ""));

    if (taskArguments.execute && callData.length > 0) {
      console.log(`\n10. --execute provided. Trying to execute this on mainnet.`);
      const { hash } = await hubPool.multicall(callData);
      console.log(`\nTransaction hash: ${hash}`);
    }
  });
