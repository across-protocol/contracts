// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";

/**
 * @title HyperCoreMockHelper
 * @notice Helper contract for setting up HyperCore precompile mocks in tests
 * @dev Inherit from this contract in your test contracts to easily mock HyperCore precompiles
 */
abstract contract HyperCoreMockHelper is Test {
    // HyperCore precompile addresses
    address internal constant CORE_USER_EXISTS_PRECOMPILE = address(0x0000000000000000000000000000000000000810);
    address internal constant TOKEN_INFO_PRECOMPILE = address(0x000000000000000000000000000000000000080C);
    address internal constant SPOT_BALANCE_PRECOMPILE = address(0x0000000000000000000000000000000000000801);
    address internal constant CORE_WRITER_PRECOMPILE = address(0x3333333333333333333333333333333333333333);

    /**
     * @notice Mock the CoreUserExists precompile
     * @param exists Whether the core user exists
     */
    function mockCoreUserExists(bool exists) internal {
        vm.mockCall(
            CORE_USER_EXISTS_PRECOMPILE,
            bytes(""), // Match any calldata
            abi.encode(exists)
        );
    }

    /**
     * @notice Mock the TokenInfo precompile with custom token information
     * @param tokenInfo The token info struct to return from the mock
     */
    function mockTokenInfo(HyperCoreLib.TokenInfo memory tokenInfo) internal {
        vm.mockCall(
            TOKEN_INFO_PRECOMPILE,
            bytes(""), // Match any calldata
            abi.encode(tokenInfo)
        );
    }

    /**
     * @notice Mock the TokenInfo precompile with default values for a token
     * @param evmContract The EVM contract address for the token
     * @param name The token name
     * @param decimals The token decimals
     */
    function mockTokenInfoDefault(address evmContract, string memory name, uint8 decimals) internal {
        HyperCoreLib.TokenInfo memory tokenInfo = HyperCoreLib.TokenInfo({
            name: name,
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: evmContract,
            szDecimals: decimals,
            weiDecimals: decimals,
            evmExtraWeiDecimals: 0
        });
        mockTokenInfo(tokenInfo);
    }

    /**
     * @notice Mock the SpotBalance precompile
     * @param spotBalance The spot balance struct to return from the mock
     */
    function mockSpotBalance(HyperCoreLib.SpotBalance memory spotBalance) internal {
        vm.mockCall(
            SPOT_BALANCE_PRECOMPILE,
            bytes(""), // Match any calldata
            abi.encode(spotBalance)
        );
    }

    /**
     * @notice Mock the SpotBalance precompile with default values
     * @param total The total balance
     * @param hold The held balance
     * @param entryNtl The entry notional value
     */
    function mockSpotBalanceDefault(uint64 total, uint64 hold, uint64 entryNtl) internal {
        HyperCoreLib.SpotBalance memory spotBalance = HyperCoreLib.SpotBalance({
            total: total,
            hold: hold,
            entryNtl: entryNtl
        });
        mockSpotBalance(spotBalance);
    }

    /**
     * @notice Mock the CoreWriter precompile
     * @param success Whether the core writer operation should succeed
     */
    function mockCoreWriter(bool success) internal {
        vm.mockCall(
            CORE_WRITER_PRECOMPILE,
            bytes(""), // Match any calldata
            abi.encode(success)
        );
    }

    /**
     * @notice Setup all HyperCore precompile mocks with default values
     * @param tokenAddress The EVM token contract address
     * @param tokenName The token name
     * @param tokenDecimals The token decimals
     * @dev This is a convenience function that mocks all precompiles with sensible defaults
     */
    function setupDefaultHyperCoreMocks(address tokenAddress, string memory tokenName, uint8 tokenDecimals) internal {
        // 1. Mock CoreUserExists precompile - user exists
        mockCoreUserExists(true);

        // 2. Mock TokenInfo precompile with default values
        mockTokenInfoDefault(tokenAddress, tokenName, tokenDecimals);

        // 3. Mock SpotBalance precompile with default balance
        mockSpotBalanceDefault(10e8, 0, 0);

        // 4. Mock CoreWriter precompile - operations succeed
        mockCoreWriter(true);
    }

    /**
     * @notice Setup all HyperCore precompile mocks with default values for multiple tokens
     * @param tokenAddresses Array of EVM token contract addresses
     * @param tokenNames Array of token names
     * @param tokenDecimals Array of token decimals
     * @dev All arrays must be the same length
     */
    function setupDefaultHyperCoreMocksMultiToken(
        address[] memory tokenAddresses,
        string[] memory tokenNames,
        uint8[] memory tokenDecimals
    ) internal {
        require(
            tokenAddresses.length == tokenNames.length && tokenNames.length == tokenDecimals.length,
            "Array length mismatch"
        );

        // Mock core user exists and core writer once
        mockCoreUserExists(true);
        mockCoreWriter(true);
        mockSpotBalanceDefault(10e8, 0, 0);

        // Mock token info for each token
        // Note: This mocks with "any calldata", so all tokens will return the last mocked value
        // For more specific mocking per token, use mockTokenInfo() with specific calldata
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            mockTokenInfoDefault(tokenAddresses[i], tokenNames[i], tokenDecimals[i]);
        }
    }

    /**
     * @notice Clear all HyperCore precompile mocks
     * @dev Useful when you need to change mock behavior mid-test
     */
    function clearHyperCoreMocks() internal {
        vm.clearMockedCalls();
    }
}
