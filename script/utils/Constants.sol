// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";

/**
 * @title Constants
 * @notice Contains constants used in deployment scripts, loaded from constants.json
 * @dev This contract uses Foundry's parseJson functions to load constants from constants.json
 */
contract Constants is Script {
    string public file;

    constructor() {
        file = vm.readFile("script/utils/constants.json");
    }

    function getChainId(string memory chainName) public view returns (uint256) {
        return vm.parseJsonUint(file, string.concat(".CHAIN_IDs.", chainName));
    }

    function QUOTE_TIME_BUFFER() public view returns (uint256) {
        return vm.parseJsonUint(file, ".TIME_CONSTANTS.QUOTE_TIME_BUFFER");
    }

    function FILL_DEADLINE_BUFFER() public view returns (uint256) {
        return vm.parseJsonUint(file, ".TIME_CONSTANTS.FILL_DEADLINE_BUFFER");
    }

    // L1 Address Map
    struct L1Addresses {
        address finder;
        address l1ArbitrumInbox;
        address l1ERC20GatewayRouter;
        address polygonRootChainManager;
        address polygonFxRoot;
        address polygonERC20Predicate;
        address polygonRegistry;
        address polygonDepositManager;
        address cctpTokenMessenger;
        address cctpV2TokenMessenger;
        address cctpMessageTransmitter;
        address lineaMessageService;
        address lineaTokenBridge;
        address scrollERC20GatewayRouter;
        address scrollMessengerRelay;
        address scrollGasPriceOracle;
        address blastYieldManager;
        address blastDaiRetriever;
        address l1AlephZeroInbox;
        address l1AlephZeroERC20GatewayRouter;
        address adapterStore;
        address donationBox;
        address hubPoolStore;
        address zkBridgeHub;
        address zkUsdcSharedBridge_232;
        address zkUsdcSharedBridge_324;
    }

    // L2 Address Map
    struct L2Addresses {
        address l2GatewayRouter;
        address fxChild;
        address cctpTokenMessenger;
        address cctpMessageTransmitter;
        address uniswapV3SwapRouter;
        address helios;
        address zkErc20Bridge;
        address zkUSDCBridge;
        address lineaMessageService;
        address cctpV2TokenMessenger;
        address lineaTokenBridge;
        address scrollERC20GatewayRouter;
        address scrollGasPriceOracle;
        address scrollMessenger;
        address l2Weth;
        address polygonZkEvmBridge;
    }

    // OP Stack Address Map
    struct OpStackAddresses {
        address L1CrossDomainMessenger;
        address L1StandardBridge;
        address L1BlastBridge;
        address L1OpUSDCBridgeAdapter;
    }

    // Helper functions to get addresses for a specific chain
    function getL1Addresses(uint256 chainId) public view returns (L1Addresses memory) {
        string memory chainIdString = vm.toString(chainId);
        if (chainId == getChainId("MAINNET") || chainId == getChainId("SEPOLIA")) {
            return
                L1Addresses({
                    finder: vm.parseJsonAddress(file, string.concat(".L1_ADDRESS_MAP.", chainIdString, ".finder")),
                    l1ArbitrumInbox: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".l1ArbitrumInbox")
                    ),
                    l1ERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".l1ERC20GatewayRouter")
                    ),
                    polygonRootChainManager: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".polygonRootChainManager")
                    ),
                    polygonFxRoot: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".polygonFxRoot")
                    ),
                    polygonERC20Predicate: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".polygonERC20Predicate")
                    ),
                    polygonRegistry: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".polygonRegistry")
                    ),
                    polygonDepositManager: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".polygonDepositManager")
                    ),
                    cctpTokenMessenger: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".cctpTokenMessenger")
                    ),
                    cctpV2TokenMessenger: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".cctpV2TokenMessenger")
                    ),
                    cctpMessageTransmitter: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".cctpMessageTransmitter")
                    ),
                    lineaMessageService: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".lineaMessageService")
                    ),
                    lineaTokenBridge: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".lineaTokenBridge")
                    ),
                    scrollERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".scrollERC20GatewayRouter")
                    ),
                    scrollMessengerRelay: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".scrollMessengerRelay")
                    ),
                    scrollGasPriceOracle: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".scrollGasPriceOracle")
                    ),
                    blastYieldManager: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".blastYieldManager")
                    ),
                    blastDaiRetriever: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".blastDaiRetriever")
                    ),
                    l1AlephZeroInbox: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".l1AlephZeroInbox")
                    ),
                    l1AlephZeroERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".l1AlephZeroERC20GatewayRouter")
                    ),
                    adapterStore: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".adapterStore")
                    ),
                    donationBox: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".donationBox")
                    ),
                    hubPoolStore: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".hubPoolStore")
                    ),
                    zkBridgeHub: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".zkBridgeHub")
                    ),
                    zkUsdcSharedBridge_232: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".zkUsdcSharedBridge_232")
                    ),
                    zkUsdcSharedBridge_324: vm.parseJsonAddress(
                        file,
                        string.concat(".L1_ADDRESS_MAP.", chainIdString, ".zkUsdcSharedBridge_324")
                    )
                });
        }
        revert("Unsupported chain ID");
    }

    function getOpStackAddresses(
        uint256 hubChainId,
        uint256 spokeChainId
    ) public view returns (OpStackAddresses memory) {
        string memory path = string.concat(
            ".OP_STACK_ADDRESS_MAP.",
            vm.toString(hubChainId),
            ".",
            vm.toString(spokeChainId)
        );

        return
            OpStackAddresses({
                L1CrossDomainMessenger: vm.parseJsonAddress(file, string.concat(path, ".L1CrossDomainMessenger")),
                L1StandardBridge: vm.parseJsonAddress(file, string.concat(path, ".L1StandardBridge")),
                L1BlastBridge: vm.parseJsonAddress(file, string.concat(path, ".L1BlastBridge")),
                L1OpUSDCBridgeAdapter: vm.parseJsonAddress(file, string.concat(path, ".L1OpUSDCBridgeAdapter"))
            });
    }

    // Circle domain IDs mapping
    function getCircleDomainId(uint256 chainId) public view returns (uint32) {
        return uint32(vm.parseJsonUint(file, string.concat(".CIRCLE_DOMAIN_IDs.", vm.toString(chainId))));
    }

    // Get WETH address for any supported chain
    function getWETHAddress(uint256 chainId) public view returns (address) {
        return vm.parseJsonAddress(file, string.concat(".WETH.", vm.toString(chainId)));
    }

    // Helper function to convert chain ID to chain name
    function _getChainName(uint256 chainId) internal view returns (string memory) {
        if (chainId == getChainId("MAINNET")) return "MAINNET";
        if (chainId == getChainId("SEPOLIA")) return "SEPOLIA";
        if (chainId == getChainId("ARBITRUM")) return "ARBITRUM";
        if (chainId == getChainId("ARBITRUM_SEPOLIA")) return "ARBITRUM_SEPOLIA";
        if (chainId == getChainId("BSC")) return "BSC";
        if (chainId == getChainId("POLYGON")) return "POLYGON";
        if (chainId == getChainId("POLYGON_AMOY")) return "POLYGON_AMOY";
        if (chainId == getChainId("ZK_SYNC")) return "ZK_SYNC";
        if (chainId == getChainId("OPTIMISM")) return "OPTIMISM";
        if (chainId == getChainId("OPTIMISM_SEPOLIA")) return "OPTIMISM_SEPOLIA";
        if (chainId == getChainId("BASE")) return "BASE";
        if (chainId == getChainId("BASE_SEPOLIA")) return "BASE_SEPOLIA";
        if (chainId == getChainId("LENS")) return "LENS";
        if (chainId == getChainId("LENS_SEPOLIA")) return "LENS_SEPOLIA";
        if (chainId == getChainId("LINEA")) return "LINEA";
        if (chainId == getChainId("SCROLL_SEPOLIA")) return "SCROLL_SEPOLIA";
        if (chainId == getChainId("SCROLL")) return "SCROLL";
        if (chainId == getChainId("UNICHAIN")) return "UNICHAIN";
        if (chainId == getChainId("UNICHAIN_SEPOLIA")) return "UNICHAIN_SEPOLIA";
        if (chainId == getChainId("ALEPH_ZERO")) return "ALEPH_ZERO";
        if (chainId == getChainId("BLAST")) return "BLAST";
        if (chainId == getChainId("BLAST_SEPOLIA")) return "BLAST_SEPOLIA";
        if (chainId == getChainId("BOBA")) return "BOBA";
        if (chainId == getChainId("INK")) return "INK";
        if (chainId == getChainId("LISK")) return "LISK";
        if (chainId == getChainId("LISK_SEPOLIA")) return "LISK_SEPOLIA";
        if (chainId == getChainId("MODE")) return "MODE";
        if (chainId == getChainId("MODE_SEPOLIA")) return "MODE_SEPOLIA";
        if (chainId == getChainId("REDSTONE")) return "REDSTONE";
        if (chainId == getChainId("SONEIUM")) return "SONEIUM";
        if (chainId == getChainId("WORLD_CHAIN")) return "WORLD_CHAIN";
        if (chainId == getChainId("ZORA")) return "ZORA";
        revert("Unsupported chain ID");
    }

    /**
     * @notice Get L2 address from constants.json
     * @param chainId The chain ID to get the address for
     * @param addressType The type of address to get (e.g., "l2GatewayRouter", "cctpTokenMessenger")
     * @return The L2 address
     */
    function getL2Address(uint256 chainId, string memory addressType) public view returns (address) {
        string memory chainName = _getChainName(chainId);
        string memory jsonPath = string(abi.encodePacked(".L2_ADDRESS_MAP.", chainName, ".", addressType));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get USDC address for the given chain
     * @param chainId The chain ID to get USDC address for
     * @return The USDC address
     */
    function getUSDCAddress(uint256 chainId) public view returns (address) {
        string memory chainName = _getChainName(chainId);
        string memory jsonPath = string(abi.encodePacked(".USDC.", chainName));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get USDC.e address for the given chain
     * @param chainId The chain ID to get USDC.e address for
     * @return The USDC.e address
     */
    function getUSDCeAddress(uint256 chainId) public view returns (address) {
        string memory chainName = _getChainName(chainId);
        string memory jsonPath = string(abi.encodePacked(".USDCe.", chainName));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get WGHO address for the given chain
     * @param chainId The chain ID to get WGHO address for
     * @return The WGHO address
     */
    function getWghoAddress(uint256 chainId) public view returns (address) {
        string memory chainName = _getChainName(chainId);
        string memory jsonPath = string(abi.encodePacked(".WGHO.", chainName));
        return vm.parseJsonAddress(file, jsonPath);
    }

    function getOftEid(uint256 chainId) public view returns (uint256) {
        string memory chainName = _getChainName(chainId);
        return vm.parseJsonUint(file, string.concat(".OFT_EIDs.", chainName));
    }
}
