// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Polygon_SpokePool } from "../../contracts/Polygon_SpokePool.sol";
import { PolygonTokenBridger } from "../../contracts/PolygonTokenBridger.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title DeployPolygonSpokePool
 * @notice Deploys the Polygon Spoke Pool contract.
 * @dev Migration of 011_deploy_polygon_spokepool.ts script to Foundry.
 */
contract DeployPolygonSpokePool is Script, ChainUtils {
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

        // Hardcoded token bridger address (should be consistent across deployments)
        address tokenBridger = 0x0330E9b4D0325cCfF515E81DFbc7754F2a02ac57;

        // Get L2 addresses
        address wmatic = getWMATIC(chainId);
        address usdc = getUSDC(chainId);
        address fxChild = getL2Address(chainId, "fxChild");
        address cctpTokenMessenger = getL2Address(chainId, "cctpTokenMessenger");

        console.log("Deploying Polygon_SpokePool on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Hub Pool: %s", hubPoolAddress);
        console.log("Token Bridger: %s", tokenBridger);
        console.log("WMATIC: %s", wmatic);
        console.log("USDC: %s", usdc);
        console.log("FX Child: %s", fxChild);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation contract
        Polygon_SpokePool spokePoolImplementation = new Polygon_SpokePool(
            wmatic,
            QUOTE_TIME_BUFFER,
            FILL_DEADLINE_BUFFER,
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Polygon_SpokePool implementation deployed at: %s", address(spokePoolImplementation));

        // Deploy ProxyAdmin contract to manage the proxyn        ProxyAdmin proxyAdmin = new ProxyAdmin();n        console.log("ProxyAdmin deployed at: %s", address(proxyAdmin));n        n        // Create initialization data for the proxyn        bytes memory initData = abi.encodeWithSelector(n            Polygon_SpokePool.initialize.selector,n            INITIAL_DEPOSIT_ID,  // Initial deposit IDn            hubPoolAddress,      // Set hub pool as cross domain adminn            hubPoolAddress       // Set hub pool as withdrawal recipientn        );n        n        // Deploy the proxy pointing to the implementation with initialization datan        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(n            address(spokePoolImplementation),n            address(proxyAdmin),     // Admin of the proxyn            initDatan        );n        console.log("Polygon_SpokePool proxy deployed at: %s", address(proxy));n        n        // Transfer ProxyAdmin ownership to the deployern        proxyAdmin.transferOwnership(deployer);n        console.log("ProxyAdmin ownership transferred to: %s", deployer);        // Note: In a real deployment, you would:
        // 1. Deploy a proxy pointing to this implementation
        // 2. Call initialize() on the proxy with:
        //    - Initial deposit ID: 1_000_000 (to avoid duplicate IDs with deprecated spoke pool)
        //    - Token Bridger: tokenBridger
        //    - Cross Domain Admin: hubPoolAddress
        //    - Withdrawal Recipient: hubPoolAddress
        //    - FX Child: fxChild

        // For example:
        // PolygonSpokePoolProxy proxy = new PolygonSpokePoolProxy(address(spokePoolImplementation));
        // Polygon_SpokePool(address(proxy)).initialize(
        //     1_000_000,
        //     PolygonTokenBridger(tokenBridger),
        //     hubPoolAddress,
        //     hubPoolAddress,
        //     fxChild
        // );
        // console.log("Polygon_SpokePool proxy deployed at: %s", address(proxy));

        vm.stopBroadcast();
    }

    // Override getWMATIC with specific Polygon implementation
    function getWMATIC(uint256 chainId) public pure override returns (address) {
        if (chainId == POLYGON) return 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;
        if (chainId == POLYGON_AMOY) return 0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889;
        revert(string.concat("No WMATIC address found for chainId ", vm.toString(chainId)));
    }

    // Override getL2Address with specific Polygon implementation
    function getL2Address(uint256 chainId, string memory key) public pure override returns (address) {
        if (chainId == POLYGON) {
            if (compareStrings(key, "fxChild")) return 0x8397259c983751DAf40400790063935a11afa28a;
            if (compareStrings(key, "cctpTokenMessenger")) return 0x9daF8c91AEFAE50b9c0E69629D3F6Ca40cA3B3FE;
        }
        if (chainId == POLYGON_AMOY) {
            if (compareStrings(key, "fxChild")) return 0xE5930336866d0388f0f745A2d9207C7781047C0f;
            if (compareStrings(key, "cctpTokenMessenger")) return 0x9f3B8679c73C2Fef8b59B4f3444d4e156fb70AA5;
        }

        revert(string.concat("No L2 address found for ", key, " on chainId ", vm.toString(chainId)));
    }
}
