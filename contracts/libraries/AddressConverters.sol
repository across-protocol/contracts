// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library Bytes32ToAddress {
    function toAddress(bytes32 _bytes32) internal pure returns (address) {
        // require(uint256(_bytes32) >> 96 == 0, "Invalid bytes32: highest 12 bytes must be 0");
        return address(uint160(uint256(_bytes32)));
    }
}

library AddressToBytes32 {
    function toBytes32(address _address) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_address)));
    }
}
