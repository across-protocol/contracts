// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ITokenRegistry } from "./interfaces/ITokenRegistry.sol";
import { HLConstants } from "./common/HLConstants.sol";

/**
 * @title PrecompileLib v1.0
 * @author Obsidian (https://x.com/ObsidianAudits)
 * @notice A library with helper functions for interacting with HyperEVM's precompiles
 */
library PrecompileLib {
    // Onchain record of token indices for each linked evm contract
    ITokenRegistry constant REGISTRY = ITokenRegistry(0x0b51d1A9098cf8a72C325003F44C194D41d7A85B);

    /*//////////////////////////////////////////////////////////////
                  Custom Utility Functions 
        (Overloads accepting token address instead of index)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets TokenInfo for a given token address by looking up its index and fetching from the precompile.
     * @dev Overload of tokenInfo(uint64 token)
     */
    function tokenInfo(address tokenAddress) internal view returns (TokenInfo memory) {
        uint64 index = getTokenIndex(tokenAddress);
        return tokenInfo(index);
    }

    /**
     * @notice Gets SpotInfo for the token/USDC market using the token address.
     * @dev Overload of spotInfo(uint64 tokenIndex)
     * Finds the spot market where USDC (index 0) is the quote.
     */
    function spotInfo(address tokenAddress) internal view returns (SpotInfo memory) {
        uint64 tokenIndex = getTokenIndex(tokenAddress);
        uint64 spotIndex = getSpotIndex(tokenIndex);
        return spotInfo(spotIndex);
    }

    /**
     * @notice Gets the spot price for the token/USDC market using the token address.
     * @dev Overload of spotPx(uint64 spotIndex)
     */
    function spotPx(address tokenAddress) internal view returns (uint64) {
        uint64 tokenIndex = getTokenIndex(tokenAddress);
        uint64 spotIndex = getSpotIndex(tokenIndex);
        return spotPx(spotIndex);
    }

    /**
     * @notice Gets a user's spot balance for a given token address.
     * @dev Overload of spotBalance(address user, uint64 token)
     */
    function spotBalance(address user, address tokenAddress) internal view returns (SpotBalance memory) {
        uint64 tokenIndex = getTokenIndex(tokenAddress);
        return spotBalance(user, tokenIndex);
    }

    /**
     * @notice Gets the index of a token from its address. Reverts if token is not linked to HyperCore.
     */
    function getTokenIndex(address tokenAddress) internal view returns (uint64) {
        return REGISTRY.getTokenIndex(tokenAddress);
    }

    /**
     * @notice Gets the spot market index for the token/USDC pair for a token using its address.
     * @dev Overload of getSpotIndex(uint64 tokenIndex)
     */
    function getSpotIndex(address tokenAddress) internal view returns (uint64) {
        uint64 tokenIndex = getTokenIndex(tokenAddress);
        return getSpotIndex(tokenIndex);
    }

    /**
     * @notice Gets the spot market index for a token.
     * @dev If only one spot market exists, returns it. Otherwise, finds the spot market with USDC as the quote token.
     */
    function getSpotIndex(uint64 tokenIndex) internal view returns (uint64) {
        uint64[] memory spots = tokenInfo(tokenIndex).spots;

        if (spots.length == 1) return spots[0];

        for (uint256 idx = 0; idx < spots.length; idx++) {
            SpotInfo memory spot = spotInfo(spots[idx]);
            if (spot.tokens[1] == 0) {
                // index 0 = USDC
                return spots[idx];
            }
        }
        revert PrecompileLib__SpotIndexNotFound();
    }

    /*//////////////////////////////////////////////////////////////
                  Using Alternate Quote Token (non USDC)
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the spot market index for a token/quote pair.
     * Iterates all spot markets for the token and matches the quote token index.
     * @dev Overload of getSpotIndex(uint64 tokenIndex)
     */
    function getSpotIndex(uint64 tokenIndex, uint64 quoteTokenIndex) internal view returns (uint64) {
        uint64[] memory spots = tokenInfo(tokenIndex).spots;

        for (uint256 idx = 0; idx < spots.length; idx++) {
            SpotInfo memory spot = spotInfo(spots[idx]);
            if (spot.tokens[1] == quoteTokenIndex) {
                return spots[idx];
            }
        }
        revert PrecompileLib__SpotIndexNotFound();
    }

    /**
     * @notice Gets SpotInfo for a token/quote pair using token addresses.
     * Looks up both token and quote indices, then finds the spot market.
     * @dev Overload of spotInfo(uint64 spotIndex)
     */
    function spotInfo(address token, address quoteToken) internal view returns (SpotInfo memory) {
        uint64 tokenIndex = getTokenIndex(token);
        uint64 quoteTokenIndex = getTokenIndex(quoteToken);
        uint64 spotIndex = getSpotIndex(tokenIndex, quoteTokenIndex);
        return spotInfo(spotIndex);
    }

    /**
     * @notice Gets the spot price for a token/quote pair using token addresses.
     * Looks up both token and quote indices, then finds the spot market.
     * @dev Overload of spotPx(uint64 spotIndex)
     */
    function spotPx(address token, address quoteToken) internal view returns (uint64) {
        uint64 tokenIndex = getTokenIndex(token);
        uint64 quoteTokenIndex = getTokenIndex(quoteToken);
        uint64 spotIndex = getSpotIndex(tokenIndex, quoteTokenIndex);
        return spotPx(spotIndex);
    }

    /*//////////////////////////////////////////////////////////////
                        Price decimals normalization
    //////////////////////////////////////////////////////////////*/

    // returns spot price as a fixed-point integer with 8 decimals
    function normalizedSpotPx(uint64 spotIndex) internal view returns (uint256) {
        SpotInfo memory info = spotInfo(spotIndex);
        uint8 baseSzDecimals = tokenInfo(info.tokens[0]).szDecimals;
        return spotPx(spotIndex) * 10 ** baseSzDecimals;
    }

    // returns mark price as a fixed-point integer with 6 decimals
    function normalizedMarkPx(uint32 perpIndex) internal view returns (uint256) {
        PerpAssetInfo memory info = perpAssetInfo(perpIndex);
        return markPx(perpIndex) * 10 ** info.szDecimals;
    }

    // returns perp oracle price as a fixed-point integer with 6 decimals
    function normalizedOraclePx(uint32 perpIndex) internal view returns (uint256) {
        PerpAssetInfo memory info = perpAssetInfo(perpIndex);
        return oraclePx(perpIndex) * 10 ** info.szDecimals;
    }

    /*//////////////////////////////////////////////////////////////
                              Precompile Calls
    //////////////////////////////////////////////////////////////*/

    function position(address user, uint16 perp) internal view returns (Position memory) {
        (bool success, bytes memory result) = HLConstants.POSITION_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, perp)
        );
        if (!success) revert PrecompileLib__PositionPrecompileFailed();
        return abi.decode(result, (Position));
    }

    function spotBalance(address user, uint64 token) internal view returns (SpotBalance memory) {
        (bool success, bytes memory result) = HLConstants.SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, token)
        );
        if (!success) revert PrecompileLib__SpotBalancePrecompileFailed();
        return abi.decode(result, (SpotBalance));
    }

    function userVaultEquity(address user, address vault) internal view returns (UserVaultEquity memory) {
        (bool success, bytes memory result) = HLConstants.VAULT_EQUITY_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, vault)
        );
        if (!success) revert PrecompileLib__VaultEquityPrecompileFailed();
        return abi.decode(result, (UserVaultEquity));
    }

    function withdrawable(address user) internal view returns (uint64) {
        (bool success, bytes memory result) = HLConstants.WITHDRAWABLE_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        if (!success) revert PrecompileLib__WithdrawablePrecompileFailed();
        return abi.decode(result, (Withdrawable)).withdrawable;
    }

    function delegations(address user) internal view returns (Delegation[] memory) {
        (bool success, bytes memory result) = HLConstants.DELEGATIONS_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        if (!success) revert PrecompileLib__DelegationsPrecompileFailed();
        return abi.decode(result, (Delegation[]));
    }

    function delegatorSummary(address user) internal view returns (DelegatorSummary memory) {
        (bool success, bytes memory result) = HLConstants.DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user)
        );
        if (!success) revert PrecompileLib__DelegatorSummaryPrecompileFailed();
        return abi.decode(result, (DelegatorSummary));
    }

    function markPx(uint32 perpIndex) internal view returns (uint64) {
        (bool success, bytes memory result) = HLConstants.MARK_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(perpIndex));
        if (!success) revert PrecompileLib__MarkPxPrecompileFailed();
        return abi.decode(result, (uint64));
    }

    function oraclePx(uint32 perpIndex) internal view returns (uint64) {
        (bool success, bytes memory result) = HLConstants.ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(perpIndex)
        );
        if (!success) revert PrecompileLib__OraclePxPrecompileFailed();
        return abi.decode(result, (uint64));
    }

    function spotPx(uint64 spotIndex) internal view returns (uint64) {
        (bool success, bytes memory result) = HLConstants.SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(spotIndex));
        if (!success) revert PrecompileLib__SpotPxPrecompileFailed();
        return abi.decode(result, (uint64));
    }

    function perpAssetInfo(uint32 perp) internal view returns (PerpAssetInfo memory) {
        (bool success, bytes memory result) = HLConstants.PERP_ASSET_INFO_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(perp)
        );
        if (!success) revert PrecompileLib__PerpAssetInfoPrecompileFailed();
        return abi.decode(result, (PerpAssetInfo));
    }

    function spotInfo(uint64 spotIndex) internal view returns (SpotInfo memory) {
        (bool success, bytes memory result) = HLConstants.SPOT_INFO_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(spotIndex)
        );
        if (!success) revert PrecompileLib__SpotInfoPrecompileFailed();
        return abi.decode(result, (SpotInfo));
    }

    function tokenInfo(uint64 token) internal view returns (TokenInfo memory) {
        (bool success, bytes memory result) = HLConstants.TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(token));
        if (!success) revert PrecompileLib__TokenInfoPrecompileFailed();
        return abi.decode(result, (TokenInfo));
    }

    function tokenSupply(uint64 token) internal view returns (TokenSupply memory) {
        (bool success, bytes memory result) = HLConstants.TOKEN_SUPPLY_PRECOMPILE_ADDRESS.staticcall(abi.encode(token));
        if (!success) revert PrecompileLib__TokenSupplyPrecompileFailed();
        return abi.decode(result, (TokenSupply));
    }

    function l1BlockNumber() internal view returns (uint64) {
        (bool success, bytes memory result) = HLConstants.L1_BLOCK_NUMBER_PRECOMPILE_ADDRESS.staticcall(abi.encode());
        if (!success) revert PrecompileLib__L1BlockNumberPrecompileFailed();
        return abi.decode(result, (uint64));
    }

    function bbo(uint64 asset) internal view returns (Bbo memory) {
        (bool success, bytes memory result) = HLConstants.BBO_PRECOMPILE_ADDRESS.staticcall(abi.encode(asset));
        if (!success) revert PrecompileLib__BboPrecompileFailed();
        return abi.decode(result, (Bbo));
    }

    function accountMarginSummary(
        uint32 perpDexIndex,
        address user
    ) internal view returns (AccountMarginSummary memory) {
        (bool success, bytes memory result) = HLConstants.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(perpDexIndex, user)
        );
        if (!success) revert PrecompileLib__AccountMarginSummaryPrecompileFailed();
        return abi.decode(result, (AccountMarginSummary));
    }

    function coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = HLConstants.CORE_USER_EXISTS_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user)
        );
        if (!success) revert PrecompileLib__CoreUserExistsPrecompileFailed();
        return abi.decode(result, (CoreUserExists)).exists;
    }

    /*//////////////////////////////////////////////////////////////
                       Structs
    //////////////////////////////////////////////////////////////*/
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    struct Withdrawable {
        uint64 withdrawable;
    }

    struct Delegation {
        address validator;
        uint64 amount;
        uint64 lockedUntilTimestamp;
    }

    struct DelegatorSummary {
        uint64 delegated;
        uint64 undelegated;
        uint64 totalPendingWithdrawal;
        uint64 nPendingWithdrawals;
    }

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    struct UserBalance {
        address user;
        uint64 balance;
    }

    struct TokenSupply {
        uint64 maxSupply;
        uint64 totalSupply;
        uint64 circulatingSupply;
        uint64 futureEmissions;
        UserBalance[] nonCirculatingUserBalances;
    }

    struct Bbo {
        uint64 bid;
        uint64 ask;
    }

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    struct CoreUserExists {
        bool exists;
    }

    error PrecompileLib__PositionPrecompileFailed();
    error PrecompileLib__SpotBalancePrecompileFailed();
    error PrecompileLib__VaultEquityPrecompileFailed();
    error PrecompileLib__WithdrawablePrecompileFailed();
    error PrecompileLib__DelegationsPrecompileFailed();
    error PrecompileLib__DelegatorSummaryPrecompileFailed();
    error PrecompileLib__MarkPxPrecompileFailed();
    error PrecompileLib__OraclePxPrecompileFailed();
    error PrecompileLib__SpotPxPrecompileFailed();
    error PrecompileLib__PerpAssetInfoPrecompileFailed();
    error PrecompileLib__SpotInfoPrecompileFailed();
    error PrecompileLib__TokenInfoPrecompileFailed();
    error PrecompileLib__TokenSupplyPrecompileFailed();
    error PrecompileLib__L1BlockNumberPrecompileFailed();
    error PrecompileLib__BboPrecompileFailed();
    error PrecompileLib__AccountMarginSummaryPrecompileFailed();
    error PrecompileLib__CoreUserExistsPrecompileFailed();
    error PrecompileLib__SpotIndexNotFound();
}
