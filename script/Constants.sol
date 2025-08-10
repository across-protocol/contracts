// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { FinderInterface } from "@uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { WETH9Interface } from "../contracts/external/interfaces/WETH9Interface.sol";

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

/**
 * @title Constants
 * @notice Contains constants used in deployment scripts, loaded from constants.json
 * @dev This contract uses Foundry's parseJson functions to load constants from constants.json
 */
contract Constants is Script {
    string public file;

    constructor() {
        file = vm.readFile("script/constants.json");
    }

    // Chain IDs - loaded from JSON
    function MAINNET() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.MAINNET");
    }

    function SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.SEPOLIA");
    }

    function ARBITRUM() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.ARBITRUM");
    }

    function ARBITRUM_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.ARBITRUM_SEPOLIA");
    }

    function BSC() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BSC");
    }

    function POLYGON() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.POLYGON");
    }

    function POLYGON_AMOY() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.POLYGON_AMOY");
    }

    function ZK_SYNC() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.ZK_SYNC");
    }

    function OPTIMISM() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.OPTIMISM");
    }

    function OPTIMISM_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.OPTIMISM_SEPOLIA");
    }

    function BASE() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BASE");
    }

    function BASE_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BASE_SEPOLIA");
    }

    function LENS() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LENS");
    }

    function LENS_TESTNET() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LENS_TESTNET");
    }

    function LINEA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LINEA");
    }

    function LINEA_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LINEA_SEPOLIA");
    }

    function SCROLL() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.SCROLL");
    }

    function SCROLL_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.SCROLL_SEPOLIA");
    }

    function UNICHAIN() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.UNICHAIN");
    }

    function UNICHAIN_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.UNICHAIN_SEPOLIA");
    }

    function ALEPH_ZERO() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.ALEPH_ZERO");
    }

    function BLAST() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BLAST");
    }

    function BLAST_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BLAST_SEPOLIA");
    }

    function BOBA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.BOBA");
    }

    function INK() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.INK");
    }

    function INK_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.INK_SEPOLIA");
    }

    function LISK() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LISK");
    }

    function LISK_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.LISK_SEPOLIA");
    }

    function MODE() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.MODE");
    }

    function MODE_SEPOLIA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.MODE_SEPOLIA");
    }

    function REDSTONE() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.REDSTONE");
    }

    function SONEIUM() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.SONEIUM");
    }

    function WORLD_CHAIN() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.WORLD_CHAIN");
    }

    function ZORA() public view returns (uint256) {
        return vm.parseJsonUint(file, ".chainIds.ZORA");
    }

    // Token addresses - loaded from JSON
    function WRAPPED_NATIVE_TOKEN_MAINNET() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.MAINNET"));
    }

    function WRAPPED_NATIVE_TOKEN_SEPOLIA() public view returns (WETH9Interface) {
        console.log("file", file);
        console.log(
            "vm.parseJsonAddress(file, '.wrappedNativeTokens.SEPOLIA')",
            vm.parseJsonAddress(file, ".wrappedNativeTokens.SEPOLIA")
        );
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_ARBITRUM() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.ARBITRUM"));
    }

    function WRAPPED_NATIVE_TOKEN_ARBITRUM_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.ARBITRUM_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_BSC() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BSC"));
    }

    function WRAPPED_NATIVE_TOKEN_POLYGON() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.POLYGON"));
    }

    function WRAPPED_NATIVE_TOKEN_POLYGON_AMOY() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.POLYGON_AMOY"));
    }

    function WRAPPED_NATIVE_TOKEN_ZK_SYNC() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.ZK_SYNC"));
    }

    function WRAPPED_NATIVE_TOKEN_OPTIMISM() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.OPTIMISM"));
    }

    function WRAPPED_NATIVE_TOKEN_OPTIMISM_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.OPTIMISM_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_BASE() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BASE"));
    }

    function WRAPPED_NATIVE_TOKEN_BASE_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BASE_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_LENS() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LENS"));
    }

    function WRAPPED_NATIVE_TOKEN_LENS_TESTNET() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LENS_TESTNET"));
    }

    function WRAPPED_NATIVE_TOKEN_LINEA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LINEA"));
    }

    function WRAPPED_NATIVE_TOKEN_LINEA_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LINEA_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_SCROLL_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.SCROLL_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_SCROLL() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.SCROLL"));
    }

    function WRAPPED_NATIVE_TOKEN_UNICHAIN() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.UNICHAIN"));
    }

    function WRAPPED_NATIVE_TOKEN_UNICHAIN_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.UNICHAIN_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_ALEPH_ZERO() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.ALEPH_ZERO"));
    }

    function WRAPPED_NATIVE_TOKEN_BLAST() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BLAST"));
    }

    function WRAPPED_NATIVE_TOKEN_BLAST_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BLAST_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_BOBA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.BOBA"));
    }

    function WRAPPED_NATIVE_TOKEN_INK() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.INK"));
    }

    function WRAPPED_NATIVE_TOKEN_LISK() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LISK"));
    }

    function WRAPPED_NATIVE_TOKEN_LISK_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.LISK_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_MODE() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.MODE"));
    }

    function WRAPPED_NATIVE_TOKEN_MODE_SEPOLIA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.MODE_SEPOLIA"));
    }

    function WRAPPED_NATIVE_TOKEN_REDSTONE() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.REDSTONE"));
    }

    function WRAPPED_NATIVE_TOKEN_SONEIUM() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.SONEIUM"));
    }

    function WRAPPED_NATIVE_TOKEN_WORLD_CHAIN() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.WORLD_CHAIN"));
    }

    function WRAPPED_NATIVE_TOKEN_ZORA() public view returns (WETH9Interface) {
        return WETH9Interface(vm.parseJsonAddress(file, ".wrappedNativeTokens.ZORA"));
    }

    // Other constants - loaded from JSON
    function ZERO_ADDRESS() public view returns (address) {
        return vm.parseJsonAddress(file, ".otherConstants.ZERO_ADDRESS");
    }

    function QUOTE_TIME_BUFFER() public view returns (uint256) {
        return vm.parseJsonUint(file, ".timeConstants.QUOTE_TIME_BUFFER");
    }

    function FILL_DEADLINE_BUFFER() public view returns (uint256) {
        return vm.parseJsonUint(file, ".timeConstants.FILL_DEADLINE_BUFFER");
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
        string memory chainName = _getChainName(chainId);
        if (chainId == MAINNET() || chainId == SEPOLIA()) {
            return
                L1Addresses({
                    finder: vm.parseJsonAddress(file, string.concat(".l1Addresses.", chainName, ".finder")),
                    l1ArbitrumInbox: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".l1ArbitrumInbox")
                    ),
                    l1ERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".l1ERC20GatewayRouter")
                    ),
                    polygonRootChainManager: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".polygonRootChainManager")
                    ),
                    polygonFxRoot: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".polygonFxRoot")
                    ),
                    polygonERC20Predicate: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".polygonERC20Predicate")
                    ),
                    polygonRegistry: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".polygonRegistry")
                    ),
                    polygonDepositManager: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".polygonDepositManager")
                    ),
                    cctpTokenMessenger: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".cctpTokenMessenger")
                    ),
                    cctpV2TokenMessenger: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".cctpV2TokenMessenger")
                    ),
                    cctpMessageTransmitter: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".cctpMessageTransmitter")
                    ),
                    lineaMessageService: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".lineaMessageService")
                    ),
                    lineaTokenBridge: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".lineaTokenBridge")
                    ),
                    scrollERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".scrollERC20GatewayRouter")
                    ),
                    scrollMessengerRelay: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".scrollMessengerRelay")
                    ),
                    scrollGasPriceOracle: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".scrollGasPriceOracle")
                    ),
                    blastYieldManager: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".blastYieldManager")
                    ),
                    blastDaiRetriever: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".blastDaiRetriever")
                    ),
                    l1AlephZeroInbox: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".l1AlephZeroInbox")
                    ),
                    l1AlephZeroERC20GatewayRouter: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".l1AlephZeroERC20GatewayRouter")
                    ),
                    donationBox: vm.parseJsonAddress(file, string.concat(".l1Addresses.", chainName, ".donationBox")),
                    hubPoolStore: vm.parseJsonAddress(file, string.concat(".l1Addresses.", chainName, ".hubPoolStore")),
                    zkBridgeHub: vm.parseJsonAddress(file, string.concat(".l1Addresses.", chainName, ".zkBridgeHub")),
                    zkUsdcSharedBridge_232: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".zkUsdcSharedBridge_232")
                    ),
                    zkUsdcSharedBridge_324: vm.parseJsonAddress(
                        file,
                        string.concat(".l1Addresses.", chainName, ".zkUsdcSharedBridge_324")
                    )
                });
        }
        revert("Unsupported chain ID");
    }

    function getOpStackAddresses(uint256 hubChainId, uint256 spokeChainId)
        public
        view
        returns (OpStackAddresses memory)
    {
        string memory hubChainName = _getChainName(hubChainId);
        string memory spokeChainName = _getChainName(spokeChainId);

        string memory path = string.concat(".opStackAddresses.", hubChainName, ".", spokeChainName);

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
        string memory chainName = _getChainName(chainId);
        return uint32(vm.parseJsonUint(file, string.concat(".circleDomainIds.", chainName)));
    }

    // Get WETH address for any supported chain
    function getWrappedNativeToken(uint256 chainId) public view returns (WETH9Interface) {
        string memory chainName = _getChainName(chainId);
        return WETH9Interface(vm.parseJsonAddress(file, string.concat(".wrappedNativeTokens.", chainName)));
    }

    // Helper function to convert chain ID to chain name
    function _getChainName(uint256 chainId) internal view returns (string memory) {
        if (chainId == MAINNET()) return "MAINNET";
        if (chainId == SEPOLIA()) return "SEPOLIA";
        if (chainId == ARBITRUM()) return "ARBITRUM";
        if (chainId == ARBITRUM_SEPOLIA()) return "ARBITRUM_SEPOLIA";
        if (chainId == BSC()) return "BSC";
        if (chainId == POLYGON()) return "POLYGON";
        if (chainId == POLYGON_AMOY()) return "POLYGON_AMOY";
        if (chainId == ZK_SYNC()) return "ZK_SYNC";
        if (chainId == OPTIMISM()) return "OPTIMISM";
        if (chainId == OPTIMISM_SEPOLIA()) return "OPTIMISM_SEPOLIA";
        if (chainId == BASE()) return "BASE";
        if (chainId == BASE_SEPOLIA()) return "BASE_SEPOLIA";
        if (chainId == LENS()) return "LENS";
        if (chainId == LENS_TESTNET()) return "LENS_TESTNET";
        if (chainId == LINEA()) return "LINEA";
        if (chainId == LINEA_SEPOLIA()) return "LINEA_SEPOLIA";
        if (chainId == SCROLL_SEPOLIA()) return "SCROLL_SEPOLIA";
        if (chainId == SCROLL()) return "SCROLL";
        if (chainId == UNICHAIN()) return "UNICHAIN";
        if (chainId == UNICHAIN_SEPOLIA()) return "UNICHAIN_SEPOLIA";
        if (chainId == ALEPH_ZERO()) return "ALEPH_ZERO";
        if (chainId == BLAST()) return "BLAST";
        if (chainId == BLAST_SEPOLIA()) return "BLAST_SEPOLIA";
        if (chainId == BOBA()) return "BOBA";
        if (chainId == INK()) return "INK";
        if (chainId == LISK()) return "LISK";
        if (chainId == LISK_SEPOLIA()) return "LISK_SEPOLIA";
        if (chainId == MODE()) return "MODE";
        if (chainId == MODE_SEPOLIA()) return "MODE_SEPOLIA";
        if (chainId == REDSTONE()) return "REDSTONE";
        if (chainId == SONEIUM()) return "SONEIUM";
        if (chainId == WORLD_CHAIN()) return "WORLD_CHAIN";
        if (chainId == ZORA()) return "ZORA";
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
        string memory jsonPath = string(abi.encodePacked(".l2Addresses.", chainName, ".", addressType));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get USDC address for the given chain
     * @param chainId The chain ID to get USDC address for
     * @return The USDC address
     */
    function getUSDCAddress(uint256 chainId) public view returns (address) {
        // Map chain ID to chain name for constants.json lookup
        if (chainId == ARBITRUM()) {
            // Arbitrum mainnet
            return vm.parseJsonAddress(file, ".usdcAddresses.ARBITRUM");
        } else if (chainId == ARBITRUM_SEPOLIA()) {
            // Arbitrum Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.ARBITRUM_SEPOLIA");
        } else if (chainId == MAINNET()) {
            // Mainnet
            return vm.parseJsonAddress(file, ".usdcAddresses.MAINNET");
        } else if (chainId == SEPOLIA()) {
            // Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.SEPOLIA");
        } else if (chainId == OPTIMISM()) {
            // Optimism
            return vm.parseJsonAddress(file, ".usdcAddresses.OPTIMISM");
        } else if (chainId == OPTIMISM_SEPOLIA()) {
            // Optimism Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.OPTIMISM_SEPOLIA");
        } else if (chainId == BASE()) {
            // Base
            return vm.parseJsonAddress(file, ".usdcAddresses.BASE");
        } else if (chainId == BASE_SEPOLIA()) {
            // Base Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.BASE_SEPOLIA");
        } else if (chainId == POLYGON()) {
            // Polygon
            return vm.parseJsonAddress(file, ".usdcAddresses.POLYGON");
        } else if (chainId == POLYGON_AMOY()) {
            // Polygon Amoy
            return vm.parseJsonAddress(file, ".usdcAddresses.POLYGON_AMOY");
        } else if (chainId == LINEA()) {
            // Linea
            return vm.parseJsonAddress(file, ".usdcAddresses.LINEA");
        } else if (chainId == LINEA_SEPOLIA()) {
            // Linea Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.LINEA_SEPOLIA");
        } else if (chainId == UNICHAIN()) {
            // Unichain
            return vm.parseJsonAddress(file, ".usdcAddresses.UNICHAIN");
        } else if (chainId == UNICHAIN_SEPOLIA()) {
            // Unichain Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.UNICHAIN_SEPOLIA");
        } else if (chainId == BLAST()) {
            // Blast
            return vm.parseJsonAddress(file, ".usdcAddresses.BLAST");
        } else if (chainId == BLAST_SEPOLIA()) {
            // Blast Sepolia
            return vm.parseJsonAddress(file, ".usdcAddresses.BLAST_SEPOLIA");
        } else {
            revert("Unsupported chain ID for USDC lookup");
        }
    }
}
