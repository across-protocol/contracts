// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";

contract ReadHCoreTokenInfoUtil is Script {
    string internal constant HCORE_JSON_PATH = "./script/mintburn/hypercore-tokens.json";
    address internal constant HYPEREVM_USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;

    struct TokenJson {
        uint256 index;
        address evmAddress;
        bool canBeUsedForAccountActivation;
        uint256 accountActivationFeeCore;
        uint256 bridgeSafetyBufferCore;
        bool isUsdc;
    }

    function readToken(string memory tokenKey) public view returns (TokenJson memory info) {
        string memory json = vm.readFile(HCORE_JSON_PATH);
        string memory base = string.concat(".", tokenKey);

        info.index = vm.parseJsonUint(json, string.concat(base, ".index"));
        info.isUsdc = _isUsdc(tokenKey);

        // evmContract.address can be null in JSON; parseJsonAddress would revert.
        try this._parseAddress(json, string.concat(base, ".evmContract.address")) returns (address a) {
            info.evmAddress = a;
        } catch {
            info.evmAddress = address(0);
        }

        // Optional fields for CoreTokenInfo. Leave defaults if absent.
        try this._parseBool(json, string.concat(base, ".canBeUsedForAccountActivation")) returns (bool canActivate) {
            info.canBeUsedForAccountActivation = canActivate;
        } catch {}
        try this._parseUint(json, string.concat(base, ".accountActivationFeeCore")) returns (uint256 activationFee) {
            info.accountActivationFeeCore = activationFee;
        } catch {}
        try this._parseUint(json, string.concat(base, ".bridgeSafetyBufferCore")) returns (uint256 bridgeSafetyBuffer) {
            info.bridgeSafetyBufferCore = bridgeSafetyBuffer;
        } catch {}
    }

    function resolveEvmAddress(TokenJson memory info) public pure returns (address evm) {
        if (info.isUsdc) return HYPEREVM_USDC;
        require(info.evmAddress != address(0), "evmAddress required in JSON");
        return info.evmAddress;
    }

    // Wrapper to make parseJsonAddress usable in try/catch (external visibility)
    function _parseAddress(string memory json, string memory key) external pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _parseBool(string memory json, string memory key) external pure returns (bool) {
        return vm.parseJsonBool(json, key);
    }

    function _parseUint(string memory json, string memory key) external pure returns (uint256) {
        return vm.parseJsonUint(json, key);
    }

    function _isUsdc(string memory tokenKey) internal pure returns (bool) {
        return keccak256(bytes(tokenKey)) == keccak256(bytes("usdc"));
    }
}
