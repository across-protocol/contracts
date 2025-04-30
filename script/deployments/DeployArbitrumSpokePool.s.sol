// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Arbitrum_SpokePool } from "../../contracts/Arbitrum_SpokePool.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title DeployArbitrumSpokePool
 * @notice Deploys the Arbitrum Spoke Pool contract.
 * @dev Migration of 005_deploy_arbitrum_spokepool.ts script to Foundry.
 */
contract DeployArbitrumSpokePool is Script, ChainUtils {
    // Constants from consts.ts
    uint32 constant QUOTE_TIME_BUFFER = 3600;
    uint32 constant FILL_DEADLINE_BUFFER = 21600; // 6 hours

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // The hub pool address should be provided as an environment variable
        address hubPoolAddress = vm.envAddress("HUB_POOL_ADDRESS");

        // Get L2 addresses
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address l2GatewayRouter = getL2Address(chainId, "l2GatewayRouter");
        address cctpTokenMessenger = getL2Address(chainId, "cctpTokenMessenger");

        console.log("Deploying Arbitrum_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("WETH: %s", weth);
        console.log("USDC: %s", usdc);
        console.log("L2 Gateway Router: %s", l2GatewayRouter);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        Arbitrum_SpokePool spokePoolImplementationImplementation = new Arbitrum_SpokePool(
            weth,
            QUOTE_TIME_BUFFER,
            FILL_DEADLINE_BUFFER,
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Arbitrum_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxyn        ProxyAdmin proxyAdmin = new ProxyAdmin();n        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));n        n        // Create initialization data for the proxyn        bytes memory initData = abi.encodeWithSelector(n            Arbitrum_SpokePool.initialize.selector,n            INITIAL_DEPOSIT_ID,  // Initial deposit IDn            hubPoolAddress,      // Set hub pool as cross domain adminn            hubPoolAddress       // Set hub pool as withdrawal recipientn        );n        n        // Deploy the proxy pointing to the implementation with initialization datan        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(n            address(spokePoolImplementation),n            address(proxyAdmin),     // Admin of the proxyn            initDatan        );n        console.log("Arbitrum_SpokePool proxy deployed at: %s", address(proxy));n        n        // Transfer ProxyAdmin ownership to the deployern        proxyAdmin.transferOwnership(deployer);n        console.log("ProxyAdmin ownership transferred to: %s", deployer);        // Note: In a real deployment, you would:
        // 1. Deploy a proxy pointing to this implementation
        // 2. Call initialize() on the proxy with:
        //    - Initial deposit ID: 1_000_000 (to avoid duplicate IDs with deprecated spoke pool)
        //    - L2 Gateway Router: l2GatewayRouter
        //    - Cross Domain Admin: hubPoolAddress
        //    - Withdrawal Recipient: hubPoolAddress

        // For example:
        // ArbitrumSpokePoolProxy proxy = new ArbitrumSpokePoolProxy(address(spokePoolImplementation));
        // Arbitrum_SpokePool(address(proxy)).initialize(
        //     1_000_000,
        //     l2GatewayRouter,
        //     hubPoolAddress,
        //     hubPoolAddress
        // );
        // console.log("Arbitrum_SpokePool proxy deployed at: %s", address(proxy));

        vm.stopBroadcast();
    }

    // Placeholder function for getting L2 addresses - this would be implemented in ChainUtils
    function getL2Address(uint256 chainId, string memory key) internal pure returns (address) {
        if (chainId == ARBITRUM) {
            if (compareStrings(key, "l2GatewayRouter")) return 0x5288c571Fd7aD117beA99bF60FE0846C4E84F933;
            if (compareStrings(key, "cctpTokenMessenger")) return 0x19330d10D9Cc8751218eaf51E8885D058642E08A;
        }
        if (chainId == ARBITRUM_SEPOLIA) {
            if (compareStrings(key, "l2GatewayRouter")) return 0x9fDD1C4E4AA24EEc1d913FABea925594a20d43C7;
            if (compareStrings(key, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
        }

        revert(string.concat("No L2 address found for ", key, " on chainId ", vm.toString(chainId)));
    }
}
