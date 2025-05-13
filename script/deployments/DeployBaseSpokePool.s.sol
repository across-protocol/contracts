// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Base_SpokePool } from "../../contracts/Base_SpokePool.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title DeployBaseSpokePool
 * @notice Deploys the Base Spoke Pool contract.
 * @dev Migration of 025_deploy_base_spokepool.ts script to Foundry.
 */
contract DeployBaseSpokePool is Script, ChainUtils {
    // Constants from consts.ts
    uint32 constant QUOTE_TIME_BUFFER = 3600;
    uint32 constant FILL_DEADLINE_BUFFER = 21600; // 6 hours
    uint32 constant INITIAL_DEPOSIT_ID = 1_000_000; // To avoid duplicate IDs with deprecated spoke pool

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // The hub pool address should be provided as an environment variable
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        // Get L2 addresses specific to this chain
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL2Address(chainId, "cctpTokenMessenger");

        console.log("Deploying Base_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("WETH: %s", weth);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        Base_SpokePool spokePoolImplementation = new Base_SpokePool(
            weth,
            QUOTE_TIME_BUFFER,
            FILL_DEADLINE_BUFFER,
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Base_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxy
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));

        // Create initialization data for the proxy
        bytes memory initData = abi.encodeWithSelector(
            Base_SpokePool.initialize.selector,
            INITIAL_DEPOSIT_ID, // Initialize deposit counter to avoid duplicate IDs
            hubPoolAddress, // Set hub pool as cross domain admin
            hubPoolAddress // Set hub pool as withdrawal recipient
        );

        // Deploy the proxy pointing to the implementation with initialization data
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(spokePoolImplementation),
            address(proxyAdmin), // Admin of the proxy
            initData
        );
        console.log("Base_SpokePool proxy deployed at: %s", address(proxy));

        // Transfer ProxyAdmin ownership to the deployer
        proxyAdmin.transferOwnership(deployer);
        console.log("ProxyAdmin ownership transferred to: %s", deployer);

        vm.stopBroadcast();
    }
}
