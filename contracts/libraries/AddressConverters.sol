// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

library Bytes32ToAddress {
    /**************************************
     *              ERRORS                *
     **************************************/
    error InvalidBytes32();

    function toAddress(bytes32 _bytes32) internal pure returns (address) {
        checkAddress(_bytes32);
        return address(uint160(uint256(_bytes32)));
    }

    function toAddressUnchecked(bytes32 _bytes32) internal pure returns (address) {
        return address(uint160(uint256(_bytes32)));
    }

    function checkAddress(bytes32 _bytes32) internal pure {
        if (uint256(_bytes32) >> 160 != 0) {
            revert InvalidBytes32();
        }
    }
}

library AddressToBytes32 {
    function toBytes32(address _address) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_address)));
    }
}
