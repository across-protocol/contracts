// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { BytesLib } from "../../external/libraries/BytesLib.sol";
import { SafeCast } from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

/**
 * @title MinimalExecutorOptions
 * @notice This library is used to provide minimal required functionality of
 * https://github.com/LayerZero-Labs/LayerZero-v2/blob/2ff4988f85b5c94032eb71bbc4073e69c078179d/packages/layerzero-v2/evm/messagelib/contracts/libs/ExecutorOptions.sol#L7
 * Code was copied, was not modified
 */
library MinimalExecutorOptions {
    uint8 internal constant WORKER_ID = 1;

    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;

    function encodeLzReceiveOption(uint128 _gas, uint128 _value) internal pure returns (bytes memory) {
        return _value == 0 ? abi.encodePacked(_gas) : abi.encodePacked(_gas, _value);
    }

    function encodeLzComposeOption(uint16 _index, uint128 _gas, uint128 _value) internal pure returns (bytes memory) {
        return _value == 0 ? abi.encodePacked(_index, _gas) : abi.encodePacked(_index, _gas, _value);
    }
}

/**
 * @title MinimalLZOptions
 * @notice This library is used to provide minimal functionality of
 * https://github.com/LayerZero-Labs/devtools/blob/52ad590ab249f660f803ae3aafcbf7115733359c/packages/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol
 * Code was copied, was not modified
 */
library MinimalLZOptions {
    // @dev Only used in `onlyType3` modifier
    using BytesLib for bytes;
    // @dev Only used in `addExecutorOption`
    using SafeCast for uint256;

    // Constants for options types
    uint16 internal constant TYPE_1 = 1; // legacy options type 1
    uint16 internal constant TYPE_2 = 2; // legacy options type 2
    uint16 internal constant TYPE_3 = 3;

    // Custom error message
    error InvalidSize(uint256 max, uint256 actual);
    error InvalidOptionType(uint16 optionType);

    // Modifier to ensure only options of type 3 are used
    modifier onlyType3(bytes memory _options) {
        if (_options.toUint16(0) != TYPE_3) revert InvalidOptionType(_options.toUint16(0));
        _;
    }

    /**
     * @dev Creates a new options container with type 3.
     * @return options The newly created options container.
     */
    function newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(TYPE_3);
    }

    /**
     * @dev Adds an executor LZ receive option to the existing options.
     * @param _options The existing options container.
     * @param _gas The gasLimit used on the lzReceive() function in the OApp.
     * @param _value The msg.value passed to the lzReceive() function in the OApp.
     * @return options The updated options container.
     *
     * @dev When multiples of this option are added, they are summed by the executor
     * eg. if (_gas: 200k, and _value: 1 ether) AND (_gas: 100k, _value: 0.5 ether) are sent in an option to the LayerZeroEndpoint,
     * that becomes (300k, 1.5 ether) when the message is executed on the remote lzReceive() function.
     */
    function addExecutorLzReceiveOption(
        bytes memory _options,
        uint128 _gas,
        uint128 _value
    ) internal pure onlyType3(_options) returns (bytes memory) {
        bytes memory option = MinimalExecutorOptions.encodeLzReceiveOption(_gas, _value);
        return addExecutorOption(_options, MinimalExecutorOptions.OPTION_TYPE_LZRECEIVE, option);
    }

    /**
     * @dev Adds an executor LZ compose option to the existing options.
     * @param _options The existing options container.
     * @param _index The index for the lzCompose() function call.
     * @param _gas The gasLimit for the lzCompose() function call.
     * @param _value The msg.value for the lzCompose() function call.
     * @return options The updated options container.
     *
     * @dev When multiples of this option are added, they are summed PER index by the executor on the remote chain.
     * @dev If the OApp sends N lzCompose calls on the remote, you must provide N incremented indexes starting with 0.
     * ie. When your remote OApp composes (N = 3) messages, you must set this option for index 0,1,2
     */
    function addExecutorLzComposeOption(
        bytes memory _options,
        uint16 _index,
        uint128 _gas,
        uint128 _value
    ) internal pure onlyType3(_options) returns (bytes memory) {
        bytes memory option = MinimalExecutorOptions.encodeLzComposeOption(_index, _gas, _value);
        return addExecutorOption(_options, MinimalExecutorOptions.OPTION_TYPE_LZCOMPOSE, option);
    }

    /**
     * @dev Adds an executor option to the existing options.
     * @param _options The existing options container.
     * @param _optionType The type of the executor option.
     * @param _option The encoded data for the executor option.
     * @return options The updated options container.
     */
    function addExecutorOption(
        bytes memory _options,
        uint8 _optionType,
        bytes memory _option
    ) internal pure onlyType3(_options) returns (bytes memory) {
        return
            abi.encodePacked(
                _options,
                MinimalExecutorOptions.WORKER_ID,
                _option.length.toUint16() + 1, // +1 for optionType
                _optionType,
                _option
            );
    }
}
