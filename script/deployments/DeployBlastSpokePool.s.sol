// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { Blast_SpokePool } from "../../contracts/Blast_SpokePool.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployBlastSpokePool
 * @notice Deploy the Blast SpokePool on a Blast chain (mainnet or testnet).
 */
contract DeployBlastSpokePool is Script, ChainUtils {
    // Constants from consts.ts
    uint32 constant QUOTE_TIME_BUFFER = 3600;
    uint32 constant FILL_DEADLINE_BUFFER = 21600; // 6 hours
    uint32 constant INITIAL_DEPOSIT_ID = 1_000_000; // to avoid duplicate IDs with deprecated spoke pool

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // The hub pool address should be provided as an environment variable
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        // Get addresses specific to this chain
        address wrappedNativeToken = getL2Address(chainId, "wrappedNative");
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL2Address(chainId, "cctpTokenMessenger");
        address usdb = getL2Address(chainId, "usdb");
        address l1Usdb = getL1Address(MAINNET, "dai"); // L1 DAI is used as L1_USDB
        address yieldRecipient = vm.envOr("YIELD_RECIPIENT", deployer);
        address blastRetriever = vm.envOr("BLAST_RETRIEVER", hubPoolAddress);

        console.log("Deploying Blast_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("Wrapped Native Token: %s", wrappedNativeToken);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);
        console.log("USDB: %s", usdb);
        console.log("L1 USDB (DAI): %s", l1Usdb);
        console.log("Yield Recipient: %s", yieldRecipient);
        console.log("Blast Retriever: %s", blastRetriever);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        Blast_SpokePool spokePoolImplementation = new Blast_SpokePool(
            wrappedNativeToken,
            QUOTE_TIME_BUFFER,
            FILL_DEADLINE_BUFFER,
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger),
            usdb,
            l1Usdb,
            yieldRecipient,
            blastRetriever
        );
        console.log("Blast_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));

        // For testing only - check if we're in a testing environment
        bool isTestingMode = vm.envOr("TESTING_MODE", false);

        // Initialize function data
        bytes memory initData;

        if (isTestingMode) {
            // In testing mode, we skip the actual initialization to avoid calling Blast contracts
            // We'll just deploy the proxy without initialization
            initData = new bytes(0);
            console.log("Running in TESTING_MODE - skipping initialization");
        } else {
            // Normal initialization with proper parameters
            initData = abi.encodeWithSelector(
                Blast_SpokePool.initialize.selector,
                INITIAL_DEPOSIT_ID, // Initial deposit ID to avoid duplicates
                hubPoolAddress, // Cross domain admin (usually Hub Pool)
                hubPoolAddress // Withdrawal recipient (usually Hub Pool)
            );
        }

        // Deploy the proxy
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(spokePoolImplementation),
            address(proxyAdmin),
            initData
        );
        console.log("Blast_SpokePool proxy deployed at: %s", address(proxy));

        // Transfer ProxyAdmin ownership to the deployer
        proxyAdmin.transferOwnership(deployer);
        console.log("ProxyAdmin ownership transferred to deployer");

        vm.stopBroadcast();
    }

    // Helper function to get L2-specific addresses for Blast
    function getL2Address(uint256 chainId, string memory contractName) public pure override returns (address) {
        // Blast addresses (mainnet and testnet)
        if (chainId == BLAST) {
            if (compareStrings(contractName, "wrappedNative")) return 0x4300000000000000000000000000000000000004;
            if (compareStrings(contractName, "usdb")) return 0x4300000000000000000000000000000000000003;
            if (compareStrings(contractName, "cctpTokenMessenger")) return address(0); // CCTP not used on Blast
        } else if (chainId == BLAST_SEPOLIA) {
            if (compareStrings(contractName, "wrappedNative")) return 0x4300000000000000000000000000000000000004;
            if (compareStrings(contractName, "usdb")) return 0x4300000000000000000000000000000000000003;
            if (compareStrings(contractName, "cctpTokenMessenger")) return address(0); // CCTP not used on Blast
        }
        return super.getL2Address(chainId, contractName);
    }
}
