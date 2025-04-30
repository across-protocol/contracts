// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { Blast_Adapter, IL1ERC20Bridge } from "../../contracts/chain-adapters/Blast_Adapter.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";

/**
 * @title DeployBlastAdapter
 * @notice Deploys the Blast_Adapter contract on Ethereum mainnet.
 */
contract DeployBlastAdapter is Script, ChainUtils {
    // Constants for Blast-specific parameters
    uint32 constant L2_GAS_LIMIT = 200000;

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get addresses specific to the current network
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address dai = getL1Address(chainId, "dai");
        address crossDomainMessenger = getBlastAddress(chainId, "crossDomainMessenger");
        address l1StandardBridge = getBlastAddress(chainId, "l1StandardBridge");
        address l1BlastBridge = getBlastAddress(chainId, "l1BlastBridge");

        console.log("Deploying Blast Adapter on chain %s", chainId);
        console.log("Deployer: %s", deployer);
        console.log("WETH: %s", weth);
        console.log("USDC: %s", usdc);
        console.log("DAI: %s", dai);
        console.log("Cross Domain Messenger: %s", crossDomainMessenger);
        console.log("L1 Standard Bridge: %s", l1StandardBridge);
        console.log("L1 Blast Bridge: %s", l1BlastBridge);

        vm.startBroadcast(deployerPrivateKey);

        Blast_Adapter adapter = new Blast_Adapter(
            WETH9Interface(weth),
            crossDomainMessenger,
            IL1StandardBridge(l1StandardBridge),
            IERC20(usdc),
            IL1ERC20Bridge(l1BlastBridge), // Interface defined in Blast_Adapter.sol
            dai,
            L2_GAS_LIMIT
        );
        console.log("Blast_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }

    // Helper function to get Blast-specific addresses
    function getBlastAddress(uint256 hubChainId, string memory contractName) internal pure returns (address) {
        if (hubChainId == MAINNET) {
            if (compareStrings(contractName, "crossDomainMessenger")) return 0xdE7355C971A5B733fe2133753Abd7e5441d441Ec;
            if (compareStrings(contractName, "l1StandardBridge")) return 0x697402166Fbf2F22E970df8a6486Ef171dbfc524;
            if (compareStrings(contractName, "l1BlastBridge")) return 0x3a05E5d33d7Ab3864D53aaEc93c8301C1Fa49115;
        } else if (hubChainId == SEPOLIA) {
            if (compareStrings(contractName, "crossDomainMessenger")) return 0x38fae5fB44562aCB6d58cF96815A9A13E0bF02fc;
            if (compareStrings(contractName, "l1StandardBridge")) return 0xfE34B7979371e080E2ad369A207bF9cA1CC5De35;
            if (compareStrings(contractName, "l1BlastBridge")) return 0x9D7F2b5Ff7568a695d54CB9E395be579f06aA2fB;
        }
        revert(
            string.concat(
                "No Blast address found for contractName ",
                contractName,
                " on chainId ",
                vm.toString(hubChainId)
            )
        );
    }
}
