// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Polygon_Adapter } from "../../contracts/chain-adapters/Polygon_Adapter.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IRootChainManager, IFxStateSender, DepositManager } from "../../contracts/chain-adapters/interfaces/AdapterInterface.sol";

/**
 * @title DeployPolygonAdapter
 * @notice Deploys the Polygon adapter contract.
 * @dev Migration of 009_deploy_polygon_adapter.ts script to Foundry.
 */
contract DeployPolygonAdapter is Script, ChainUtils {
    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get addresses specific to the current network
        address rootChainManager = getL1Address(chainId, "polygonRootChainManager");
        address fxRoot = getL1Address(chainId, "polygonFxRoot");
        address depositManager = getL1Address(chainId, "polygonDepositManager");
        address erc20Predicate = getL1Address(chainId, "polygonERC20Predicate");
        address matic = getMATIC(chainId);
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL1Address(chainId, "cctpTokenMessenger");

        console.log("Deploying Polygon Adapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("Root Chain Manager: %s", rootChainManager);
        console.log("FX Root: %s", fxRoot);
        console.log("Deposit Manager: %s", depositManager);
        console.log("ERC20 Predicate: %s", erc20Predicate);
        console.log("MATIC: %s", matic);
        console.log("WETH: %s", weth);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Polygon_Adapter
        Polygon_Adapter adapter = new Polygon_Adapter(
            IRootChainManager(rootChainManager),
            IFxStateSender(fxRoot),
            DepositManager(depositManager),
            erc20Predicate,
            matic,
            WETH9Interface(weth),
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Polygon_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }

    // Helper function to get MATIC token address
    function getMATIC(uint256 chainId) internal pure returns (address) {
        if (chainId == MAINNET) return 0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0;
        if (chainId == SEPOLIA) return 0x655F2166b0709cd575202630952D71E2bB0d61Af;
        revert(string.concat("No MATIC address found for chainId ", vm.toString(chainId)));
    }
}
