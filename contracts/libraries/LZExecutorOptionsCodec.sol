// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title LZExecutorOptionsCodec
 * @notice Helper encoding library based on https://gist.github.com/St0rmBr3w/32faac27973f5886ed712c3422408b06
 * @notice Licensing note: https://gist.github.com/St0rmBr3w/32faac27973f5886ed712c3422408b06#licensing-note
 */
library LZExecutorOptionsCodec {
    uint8 internal constant EXECUTOR_WORKER_ID = 1;

    // Based on https://gist.github.com/St0rmBr3w/32faac27973f5886ed712c3422408b06#1-option_type_lzreceive-type-1
    uint8 internal constant OPTION_TYPE_LZRECEIVE = 1;
    function encodeLzReceiveOptionData(uint128 _gas, uint128 _value) internal pure returns (bytes memory) {
        return _value == 0 ? abi.encodePacked(_gas) : abi.encodePacked(_gas, _value);
    }

    // Based on https://gist.github.com/St0rmBr3w/32faac27973f5886ed712c3422408b06#3-option_type_lzcompose-type-3
    uint8 internal constant OPTION_TYPE_LZCOMPOSE = 3;
    function encodeLzComposeOptionData(uint16 _idx, uint128 _gas, uint128 _value) internal pure returns (bytes memory) {
        return _value == 0 ? abi.encodePacked(_idx, _gas) : abi.encodePacked(_idx, _gas, _value);
    }
}
