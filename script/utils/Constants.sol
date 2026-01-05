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
        file = vm.readFile("generated/constants.json");
    }

    function getChainId(string memory chainName) public view returns (uint256) {
        return vm.parseJsonUint(file, string.concat(".CHAIN_IDs.", chainName));
    }

    function getTestnetChainIds() public view returns (uint256[] memory) {
        return vm.parseJsonUintArray(file, ".TESTNET_CHAIN_IDs");
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
        int32 cctpDomain = _getCctpDomain(chainId);
        if (cctpDomain == -1) {
            revert("Circle domain ID not found");
        }
        return uint32(cctpDomain);
    }

    function hasCctpDomain(uint256 chainId) public view returns (bool) {
        return _getCctpDomain(chainId) != -1;
    }

    function _getCctpDomain(uint256 chainId) internal view returns (int32) {
        return int32(vm.parseJsonInt(file, string.concat(".PUBLIC_NETWORKS.", vm.toString(chainId), ".cctpDomain")));
    }

    function getOftEid(uint256 chainId) public view returns (uint256) {
        int256 oftEid = vm.parseJsonInt(file, string.concat(".PUBLIC_NETWORKS.", vm.toString(chainId), ".oftEid"));
        if (oftEid == -1) {
            revert("OFT EID not found");
        }
        return uint256(oftEid);
    }

    function getChainFamily(uint256 chainId) public view returns (string memory) {
        return vm.parseJsonString(file, string.concat(".PUBLIC_NETWORKS.", vm.toString(chainId), ".family"));
    }

    // Get WETH address for any supported chain
    function getWETHAddress(uint256 chainId) public view returns (address) {
        return vm.parseJsonAddress(file, string.concat(".WETH.", vm.toString(chainId)));
    }

    function getWrappedNativeToken(uint256 chainId) public view returns (address) {
        return vm.parseJsonAddress(file, string.concat(".WRAPPED_NATIVE_TOKENS.", vm.toString(chainId)));
    }

    /**
     * @notice Get L2 address from constants.json
     * @param chainId The chain ID to get the address for
     * @param addressType The type of address to get (e.g., "l2GatewayRouter", "cctpTokenMessenger")
     * @return The L2 address
     */
    function getL2Address(uint256 chainId, string memory addressType) public view returns (address) {
        string memory jsonPath = string(abi.encodePacked(".L2_ADDRESS_MAP.", vm.toString(chainId), ".", addressType));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get USDC address for the given chain
     * @param chainId The chain ID to get USDC address for
     * @return The USDC address
     */
    function getUSDCAddress(uint256 chainId) public view returns (address) {
        string memory jsonPath = string(abi.encodePacked(".USDC.", vm.toString(chainId)));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get USDC.e address for the given chain
     * @param chainId The chain ID to get USDC.e address for
     * @return The USDC.e address
     */
    function getUSDCeAddress(uint256 chainId) public view returns (address) {
        string memory jsonPath = string(abi.encodePacked(".USDCe.", vm.toString(chainId)));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get WGHO address for the given chain
     * @param chainId The chain ID to get WGHO address for
     * @return The WGHO address
     */
    function getWghoAddress(uint256 chainId) public view returns (address) {
        string memory jsonPath = string(abi.encodePacked(".WGHO.", vm.toString(chainId)));
        return vm.parseJsonAddress(file, jsonPath);
    }

    /**
     * @notice Get WMATIC address for the given chain
     * @param chainId The chain ID to get WMATIC address for
     * @return The WMATIC address
     */
    function getWmaticAddress(uint256 chainId) public view returns (address) {
        string memory jsonPath = string(abi.encodePacked(".WMATIC.", vm.toString(chainId)));
        return vm.parseJsonAddress(file, jsonPath);
    }
}
