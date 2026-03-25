// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { Constants } from "../utils/Constants.sol";

contract ReadHCoreTokenInfoUtil is Script {
    string internal constant HCORE_JSON_PATH = "./script/mintburn/hypercore-tokens.json";

    struct TokenJson {
        uint256 index;
        address evmAddress;
        bool canBeUsedForAccountActivation;
        uint256 accountActivationFeeCore;
        uint256 bridgeSafetyBufferCore;
    }

    function readToken(string memory tokenName) public view returns (TokenJson memory info) {
        string memory json = vm.readFile(HCORE_JSON_PATH);
        string memory base = string.concat(".", tokenName);

        info.index = vm.parseJsonUint(json, string.concat(base, ".index"));

        // evmAddress can be null in JSON; parseJsonAddress would revert. Try/catch and leave zero if unset.
        try this._parseAddress(json, string.concat(base, ".evmAddress")) returns (address a) {
            info.evmAddress = a;
        } catch {
            info.evmAddress = address(0);
        }

        // Required fields for CoreTokenInfo
        info.canBeUsedForAccountActivation = vm.parseJsonBool(
            json,
            string.concat(base, ".canBeUsedForAccountActivation")
        );
        info.accountActivationFeeCore = vm.parseJsonUint(json, string.concat(base, ".accountActivationFeeCore"));
        info.bridgeSafetyBufferCore = vm.parseJsonUint(json, string.concat(base, ".bridgeSafetyBufferCore"));
    }

    function resolveEvmAddress(TokenJson memory info, uint256 /* chainId */) public pure returns (address evm) {
        require(info.evmAddress != address(0), "evmAddress required in JSON");
        return info.evmAddress;
    }

    // Wrapper to make parseJsonAddress usable in try/catch (external visibility)
    function _parseAddress(string memory json, string memory key) external pure returns (address) {
        return vm.parseJsonAddress(json, key);
    }
}
