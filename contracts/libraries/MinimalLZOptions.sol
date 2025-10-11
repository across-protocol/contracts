// SPDX-License-Identifier: MIT

pragma solidity ^0.8.23;

/**
 * @title MinimalLZOptions
 * @notice This library is used to provide minimal functionality of
 * https://github.com/LayerZero-Labs/devtools/blob/52ad590ab249f660f803ae3aafcbf7115733359c/packages/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol
 */
library MinimalLZOptions {
    uint16 internal constant TYPE_3 = 3;

    uint8 internal constant EXECUTOR_WORKER_ID = 1;
    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;
    uint8 internal constant OPTION_TYPE_NATIVE_DROP = 2; // not used but reserved for completeness
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;

    error InvalidOptionType(uint16 optionType);

    function newOptions() internal pure returns (bytes memory) {
        return abi.encodePacked(TYPE_3);
    }

    function addExecutorLzReceiveOption(
        bytes memory options,
        uint128 gasLimit,
        uint128 msgValue
    ) internal pure returns (bytes memory) {
        _requireType3(options);
        bytes memory encoded = _encodeLzReceiveOption(gasLimit, msgValue);
        return _addExecutorOption(options, OPTION_TYPE_LZRECEIVE, encoded);
    }

    function addExecutorLzComposeOption(
        bytes memory options,
        uint16 index,
        uint128 gasLimit,
        uint128 msgValue
    ) internal pure returns (bytes memory) {
        _requireType3(options);
        bytes memory encoded = _encodeLzComposeOption(index, gasLimit, msgValue);
        return _addExecutorOption(options, OPTION_TYPE_LZCOMPOSE, encoded);
    }

    function _requireType3(bytes memory options) private pure {
        if (options.length < 2) revert InvalidOptionType(0);
        uint16 optType;
        assembly {
            // options points to bytes data; first 32 bytes is length
            // Read first 2 bytes of data at offset 32
            let ptr := add(options, 32)
            optType := shr(240, mload(ptr)) // load 32 bytes, take high 16 bits
        }
        if (optType != TYPE_3) revert InvalidOptionType(optType);
    }

    function _addExecutorOption(
        bytes memory options,
        uint8 optionType,
        bytes memory option
    ) private pure returns (bytes memory) {
        // size = len(optionType) + len(option) = 1 + option.length
        uint16 size = uint16(1 + option.length);
        return abi.encodePacked(options, EXECUTOR_WORKER_ID, size, optionType, option);
    }

    function _encodeLzReceiveOption(uint128 gasLimit, uint128 msgValue) private pure returns (bytes memory) {
        return msgValue == 0 ? abi.encodePacked(gasLimit) : abi.encodePacked(gasLimit, msgValue);
    }

    function _encodeLzComposeOption(
        uint16 index,
        uint128 gasLimit,
        uint128 msgValue
    ) private pure returns (bytes memory) {
        return msgValue == 0 ? abi.encodePacked(index, gasLimit) : abi.encodePacked(index, gasLimit, msgValue);
    }
}
