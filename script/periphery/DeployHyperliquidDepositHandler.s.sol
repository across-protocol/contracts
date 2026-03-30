// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { HyperliquidDepositHandler } from "../../contracts/handlers/HyperliquidDepositHandler.sol";
import { ReadHCoreTokenInfoUtil } from "../mintburn/ReadHCoreTokenInfoUtil.s.sol";
import { DeployedAddresses } from "../utils/DeployedAddresses.sol";
import { SafeCast } from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

/*
How to run:

# signer defaults to deployer
forge script script/DeployHyperliquidDepositHandler.s.sol:DeployHyperliquidDepositHandler \
  --sig "run(string[])" '["usdt0","usdc","usdh"]' --rpc-url hyperevm -vvvv --broadcast --verify

# explicit signer override (pass zero address to use deployer)
SIGNER=0x1111111111111111111111111111111111111111
forge script script/DeployHyperliquidDepositHandler.s.sol:DeployHyperliquidDepositHandler \
  --sig "run(string[],address)" '["usdt0","usdc","usdh"]' $SIGNER --rpc-url hyperevm -vvvv --broadcast --verify
*/

contract DeployHyperliquidDepositHandler is Script, DeployedAddresses {
    using SafeCast for uint256;

    string internal constant SPOKE_POOL_NAME = "SpokePool";
    string internal constant ADD_SUPPORTED_TOKEN_SIG = "addSupportedToken(address,uint32,bool,uint64,uint64)";

    struct TokenConfig {
        string symbol;
        address evmAddress;
        uint32 coreIndex;
        bool canBeUsedForAccountActivation;
        uint64 accountActivationFeeCore;
        uint64 bridgeSafetyBufferCore;
    }

    function run() external pure {
        revert("Missing args. Use run(string[] tokenSymbols[, address signer])");
    }

    function run(string[] memory tokenSymbols) external {
        _run(tokenSymbols, address(0));
    }

    function run(string[] memory tokenSymbols, address signerOverride) external {
        _run(tokenSymbols, signerOverride);
    }

    function _run(string[] memory tokenSymbols, address signerOverride) internal {
        require(tokenSymbols.length != 0, "token symbols required");

        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        address signer = signerOverride == address(0) ? deployer : signerOverride;
        uint256 chainId = block.chainid;
        address spokePool = getAddress(chainId, SPOKE_POOL_NAME);
        require(spokePool != address(0), "SpokePool missing in broadcast/deployed-addresses.json");
        address donationBox = 0x1648fC159a5c13c060EFdF44f3CEE9bD184fa168;

        ReadHCoreTokenInfoUtil reader = new ReadHCoreTokenInfoUtil();
        TokenConfig[] memory tokenConfigs = new TokenConfig[](tokenSymbols.length);
        for (uint256 i = 0; i < tokenSymbols.length; i++) {
            string memory tokenSymbol = tokenSymbols[i];
            require(bytes(tokenSymbol).length != 0, "empty token symbol");
            ReadHCoreTokenInfoUtil.TokenJson memory info = reader.readToken(tokenSymbol);
            tokenConfigs[i] = TokenConfig({
                symbol: tokenSymbol,
                evmAddress: reader.resolveEvmAddress(info),
                coreIndex: info.index.toUint32(),
                canBeUsedForAccountActivation: info.canBeUsedForAccountActivation,
                accountActivationFeeCore: info.accountActivationFeeCore.toUint64(),
                bridgeSafetyBufferCore: info.bridgeSafetyBufferCore.toUint64()
            });
        }

        console.log("Chain ID:", chainId);
        console.log("SpokePool:", spokePool);
        console.log("Deployer:", deployer);
        console.log("Signer required to sign payloads for handleV3AcrossMessage:", signer);

        vm.startBroadcast(deployerPrivateKey);
        HyperliquidDepositHandler hyperliquidDepositHandler = new HyperliquidDepositHandler(
            donationBox,
            signer,
            spokePool
        );
        vm.stopBroadcast();

        address deployedHandler = address(hyperliquidDepositHandler);
        console.log("HyperliquidDepositHandler deployed to:", deployedHandler);
        console.log("Configured token count:", tokenConfigs.length);
        _printPostDeploySteps(deployedHandler, tokenConfigs);
    }

    function _printPostDeploySteps(address deployedHandler, TokenConfig[] memory tokenConfigs) internal pure {
        console.log("POST-DEPLOY STEPS (manual):");
        console.log("Foundry scripts cannot currently execute HyperCore precompile-dependent setup flows.");
        console.log("TODO: when precompile simulation support is available, inline these setup calls in this script.");
        console.log("1) Activate HyperCore account for the deployed handler.");
        console.log("   Handler:", deployedHandler);
        console.log("   Use Hyperliquid UI/API to send 1 core wei to this address.");
        console.log("   Suggested activation token:", tokenConfigs[0].symbol);

        for (uint256 i = 0; i < tokenConfigs.length; i++) {
            TokenConfig memory cfg = tokenConfigs[i];
            uint256 stepNum = i + 2;
            string memory canActivate = cfg.canBeUsedForAccountActivation ? "true" : "false";

            console.log(
                string(abi.encodePacked(vm.toString(stepNum), ") Configure ", cfg.symbol, " via addSupportedToken"))
            );
            console.log("   Function:", ADD_SUPPORTED_TOKEN_SIG);
            console.log("   token:", cfg.evmAddress);
            console.log("   coreIndex:", uint256(cfg.coreIndex));
            console.log("   canBeUsedForAccountActivation:", cfg.canBeUsedForAccountActivation);
            console.log("   accountActivationFeeCore:", uint256(cfg.accountActivationFeeCore));
            console.log("   bridgeSafetyBufferCore:", uint256(cfg.bridgeSafetyBufferCore));
            console.log("   Command:");
            console.log(
                string(
                    abi.encodePacked(
                        "   cast send ",
                        vm.toString(deployedHandler),
                        ' "',
                        ADD_SUPPORTED_TOKEN_SIG,
                        '" ',
                        vm.toString(cfg.evmAddress),
                        " ",
                        vm.toString(cfg.coreIndex),
                        " ",
                        canActivate,
                        " ",
                        vm.toString(cfg.accountActivationFeeCore),
                        " ",
                        vm.toString(cfg.bridgeSafetyBufferCore),
                        " --rpc-url hyperevm --account <ACCOUNT>"
                    )
                )
            );
        }
    }
}
