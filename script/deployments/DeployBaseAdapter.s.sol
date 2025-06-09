// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Base_Adapter } from "../../contracts/chain-adapters/Base_Adapter.sol";
import { ChainUtils } from "../../script/utils/ChainUtils.sol";
import { WETH9Interface } from "../../contracts/external/interfaces/WETH9Interface.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ITokenMessenger } from "../../contracts/external/interfaces/CCTPInterfaces.sol";
import { IL1StandardBridge } from "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";

/**
 * @title DeployBaseAdapter
 * @notice Deploys the Base adapter contract.
 * @dev Migration of 024_deploy_base_adapter.ts script to Foundry.
 */
contract DeployBaseAdapter is Script, ChainUtils {
    // Chain ID of the spoke chain
    uint256 constant SPOKE_CHAIN_ID = 8453; // Base chain ID

    function run() external {
        string memory deployerMnemonic = vm.envString("MNEMONIC");
        uint256 deployerPrivateKey = vm.deriveKey(deployerMnemonic, 0);
        address deployer = vm.addr(deployerPrivateKey);
        uint256 chainId = block.chainid;

        // Get addresses specific to the current network
        address weth = getWETH(chainId);
        address usdc = getUSDC(chainId);
        address cctpTokenMessenger = getL1Address(chainId, "cctpTokenMessenger");

        // Get OP Stack addresses for this specific L2
        address l1CrossDomainMessenger = getOpStackAddress(chainId, SPOKE_CHAIN_ID, "L1CrossDomainMessenger");
        address l1StandardBridge = getOpStackAddress(chainId, SPOKE_CHAIN_ID, "L1StandardBridge");

        console.log("Deploying Base Adapter on chain %s for spoke chain %s", chainId, SPOKE_CHAIN_ID);
        console.log("Deployer: %s", deployer);
        console.log("WETH: %s", weth);
        console.log("L1CrossDomainMessenger: %s", l1CrossDomainMessenger);
        console.log("L1StandardBridge: %s", l1StandardBridge);
        console.log("USDC: %s", usdc);
        console.log("CCTP Token Messenger: %s", cctpTokenMessenger);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Base_Adapter
        Base_Adapter adapter = new Base_Adapter(
            WETH9Interface(weth),
            l1CrossDomainMessenger,
            IL1StandardBridge(l1StandardBridge),
            IERC20(usdc),
            ITokenMessenger(cctpTokenMessenger)
        );
        console.log("Base_Adapter deployed at: %s", address(adapter));

        vm.stopBroadcast();
    }

    // Helper function to get OP Stack addresses
    function getOpStackAddress(
        uint256 hubChainId,
        uint256 spokeChainId,
        string memory contractName
    ) internal pure returns (address) {
        if (hubChainId == MAINNET) {
            if (spokeChainId == BASE) {
                if (compareStrings(contractName, "L1CrossDomainMessenger"))
                    return 0x866E82a600A1414e583f7F13623F1aC5d58b0Afa;
                if (compareStrings(contractName, "L1StandardBridge")) return 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;
            }
        } else if (hubChainId == SEPOLIA) {
            if (spokeChainId == BASE_SEPOLIA) {
                if (compareStrings(contractName, "L1CrossDomainMessenger"))
                    return 0xC34855F4De64F1840e5686e64278da901e261f20;
                if (compareStrings(contractName, "L1StandardBridge")) return 0xfd0Bf71F60660E2f608ed56e1659C450eB113120;
            }
        }

        revert(
            string.concat(
                "No OP stack address found for ",
                contractName,
                " on hubChainId ",
                vm.toString(hubChainId),
                " and spokeChainId ",
                vm.toString(spokeChainId)
            )
        );
    }
}
