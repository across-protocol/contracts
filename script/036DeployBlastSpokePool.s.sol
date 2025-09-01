// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { Blast_SpokePool } from "../contracts/Blast_SpokePool.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";
import { DeploymentUtils } from "./utils/DeploymentUtils.sol";

// How to run:
// 1. `source .env` where `.env` has MNEMONIC="x x x ... x"
// 2. forge script script/036DeployBlastSpokePool.s.sol:DeployBlastSpokePool --rpc-url $NODE_URL_1 -vvvv
// 3. Verify the above works in simulation mode.
// 4. Deploy with: forge script script/036DeployBlastSpokePool.s.sol:DeployBlastSpokePool --rpc-url $NODE_URL_1 --broadcast --verify

contract DeployBlastSpokePool is Script, Test, DeploymentUtils {
    // USDB addresses for Blast chains
    // These addresses are from @across-protocol/constants package
    address constant BLAST_USDB = 0x4300000000000000000000000000000000000003; // Blast mainnet USDB
    address constant BLAST_SEPOLIA_USDB = 0x4200000000000000000000000000000000000023; // Blast Sepolia USDB
    address constant MAINNET_DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // Mainnet DAI
    address constant SEPOLIA_DAI = 0x68194a729C2450ad26072b3D33ADaCbcef39D574; // Sepolia DAI

    // Yield recipient address (from the original deployment script)
    address constant YIELD_RECIPIENT = 0x8bA929bE3462a809AFB3Bf9e100Ee110D2CFE531;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);

        // Get deployment information
        DeploymentInfo memory info = getSpokePoolDeploymentInfo(address(0));

        console.log("HubPool address:", info.hubPool);

        // Get the appropriate addresses for this chain
        WETH9Interface weth = getWrappedNativeToken(info.spokeChainId);

        // Get USDB and DAI addresses based on chain
        address usdb = getUSDBAddress(info.spokeChainId);
        address dai = getDAIAddress(info.hubChainId);
        address blastRetriever = getL1Addresses(info.hubChainId).blastDaiRetriever;

        vm.startBroadcast(deployerPrivateKey);

        // Prepare constructor arguments for Blast_SpokePool
        bytes memory constructorArgs = abi.encode(
            address(weth), // _wrappedNativeTokenAddress
            QUOTE_TIME_BUFFER(), // _depositQuoteTimeBuffer
            FILL_DEADLINE_BUFFER(), // _fillDeadlineBuffer
            address(0), // _l2Usdc
            address(0), // _cctpTokenMessenger
            usdb, // usdb
            dai, // l1Usdb (DAI)
            YIELD_RECIPIENT, // yieldRecipient
            blastRetriever // blastRetriever
        );

        // Initialize deposit counter to very high number of deposits to avoid duplicate deposit ID's
        // with deprecated spoke pool.
        // Set hub pool as cross domain admin since it delegatecalls the Adapter logic.
        bytes memory initArgs = abi.encodeWithSelector(
            Blast_SpokePool.initialize.selector,
            1_000_000, // _initialDepositId
            info.hubPool, // _crossDomainAdmin
            info.hubPool // _withdrawalRecipient
        );

        // Deploy the proxy
        DeploymentResult memory result = deployNewProxy(
            "Blast_SpokePool",
            constructorArgs,
            initArgs,
            true // implementationOnly
        );

        // Log the deployed addresses
        console.log("Chain ID:", info.spokeChainId);
        console.log("Hub Chain ID:", info.hubChainId);
        console.log("HubPool address:", info.hubPool);
        console.log("WETH address:", address(weth));
        console.log("USDB address:", usdb);
        console.log("DAI address:", dai);
        console.log("Yield Recipient:", YIELD_RECIPIENT);
        console.log("Blast Retriever:", blastRetriever);
        console.log("Blast_SpokePool proxy deployed to:", result.proxy);
        console.log("Blast_SpokePool implementation deployed to:", result.implementation);

        console.log("QUOTE_TIME_BUFFER()", QUOTE_TIME_BUFFER());
        console.log("FILL_DEADLINE_BUFFER()", FILL_DEADLINE_BUFFER());

        vm.stopBroadcast();
    }

    function getUSDBAddress(uint256 chainId) internal view returns (address) {
        if (chainId == getChainId("BLAST")) {
            // BLAST
            return BLAST_USDB;
        } else if (chainId == getChainId("BLAST_SEPOLIA")) {
            // BLAST_SEPOLIA
            return BLAST_SEPOLIA_USDB;
        } else {
            revert("Unsupported chain for USDB");
        }
    }

    function getDAIAddress(uint256 chainId) internal view returns (address) {
        if (chainId == getChainId("MAINNET")) {
            // MAINNET
            return MAINNET_DAI;
        } else if (chainId == getChainId("SEPOLIA")) {
            // SEPOLIA
            return SEPOLIA_DAI;
        } else {
            revert("Unsupported chain for DAI");
        }
    }
}
