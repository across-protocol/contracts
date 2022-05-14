import { task } from "hardhat/config";
import assert from "assert";
import { findL2TokenForL1Token, askYesNoQuestion, zeroAddress, minimalSpokePoolInterface } from "./utils";

const enabledChainIds = [1, 10, 137, 288, 42161]; // Supported mainnet chain IDs.

task("enable-l1-token-across-ecosystem", "Enable a provided token across the entire ecosystem of supported chains")
  .addParam("chain1token", "Address of the token to enable, as defined on L1")
  .addOptionalParam("chain10token", "Address of the token on chainID 10. Used to override the auto detect")
  .addOptionalParam("chain137token", "Address of the token on chainID 137. Used to override the auto detect")
  .addOptionalParam("chain288token", "Address of the token on chainID 288. Used to override the auto detect")
  .addOptionalParam("chain42161token", "Address of the token on chainID 42161. Used to override the auto detect")
  .setAction(async function (taskArguments, hre_) {
    const hre = hre_ as any;
    const l1Token = taskArguments.chain1token;
    assert(l1Token, "chain1token argument must be provided");
    console.log(`\n0. Running task to enable L1 token over entire Across ecosystem 🌉. L1 token: ${l1Token}`);
    const { deployments, ethers } = hre;
    const signer = (await hre.ethers.getSigners())[0];

    console.log("\n1. Auto detecting L2 companion token address for provided L1 token.");
    const autoDetectedTokens = await Promise.all(
      enabledChainIds.slice(1).map((chainId) => findL2TokenForL1Token(chainId, l1Token))
    );

    const tokens: string[] = [];
    tokens[0] = l1Token;
    enabledChainIds
      .slice(1)
      .forEach(
        (chainId, index) => (tokens[index + 1] = taskArguments[`chain${chainId}token`] ?? autoDetectedTokens[index])
      );

    console.table(
      enabledChainIds.map((chainId, index) => {
        return { chainId, address: tokens[index], autoDetected: taskArguments[`chain${chainId}token`] == undefined };
      }),
      ["chainId", "address", "autoDetected"]
    );

    enabledChainIds.forEach((chainId, index) => assert(tokens[index] !== zeroAddress, `Bad address on ${chainId}`));

    // Check the user is ok with the token addresses provided. If not, abort.
    if (!(await askYesNoQuestion("\n2. Do these token addresses match with your expectation?"))) process.exit(0);

    // Construct an ethers contract to access the `interface` prop to create encoded function calls.
    const hubPoolDeployment = await deployments.get("HubPool");
    const hubPool = new ethers.Contract(hubPoolDeployment.address, hubPoolDeployment.abi, signer);

    console.log("\n4. Constructing calldata to enable these tokens. Using HubPool at address:", hubPool.address);

    // Construct calldata to enable these tokens.
    let callData = [];
    console.log("\n5. Adding calldata to enable liquidity provision on", l1Token);
    callData.push(hubPool.interface.encodeFunctionData("enableL1TokenForLiquidityProvision", [l1Token]));

    console.log("\n6. Adding calldata to enable routes between all chains and tokens:");
    let i = 0; // counter for logging.
    enabledChainIds.forEach((fromId, fromIndex) => {
      enabledChainIds.forEach((toId, toIndex) => {
        if (fromId === toId) return;

        console.log(`\t 6.${++i}\t Adding calldata for token ${tokens[fromIndex]} for route ${fromId} -> ${toId}`);
        callData.push(hubPool.interface.encodeFunctionData("setDepositRoute", [fromId, toId, tokens[fromIndex], true]));
      });
    });

    console.log("\n7. Adding calldata to set the pool rebalance route for the respective destination tokens:");
    enabledChainIds.forEach((toId, toIndex) => {
      console.log(`\t 7.${toIndex}\t Adding calldata for rebalance route for L2Token ${tokens[toIndex]} on ${toId}`);
      callData.push(hubPool.interface.encodeFunctionData("setPoolRebalanceRoute", [toId, l1Token, tokens[toIndex]]));
    });

    console.log("\n8. Adding call data to whitelist L1 token on Arbitrum. This is only needed on this chain");

    const spokePool = new ethers.Contract(hubPoolDeployment.address, minimalSpokePoolInterface, signer);
    // Find the address of the the Arbitrum representation of this token. Construct whitelistToken call to send to the
    // Arbitrum spoke pool via the relaySpokeAdminFunction call.
    const arbitrumToken = tokens[enabledChainIds.indexOf(42161)];
    const whitelistTokenCallData = spokePool.interface.encodeFunctionData("whitelistToken", [arbitrumToken, l1Token]);
    callData.push(hubPool.interface.encodeFunctionData("relaySpokePoolAdminFunction", [42161, whitelistTokenCallData]));

    console.log(`\n9. ***DONE.***\nCalldata to enable desired token has been constructed!`);
    console.log(`CallData contains ${callData.length} transactions, which can be sent in one multicall🚀`);
    console.log(JSON.stringify(callData).replace(/"/g, ""));
  });
