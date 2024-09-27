// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title AddressUtils
 * @notice This library contains internal functions for manipulating addresses.
 */
library CrossDomainAddressUtils {
    // L1 addresses are transformed during l1->l2 calls.
    // This cannot be pulled directly from Arbitrum contracts because their contracts are not 0.8.X compatible and
    // this operation takes advantage of overflows, whose behavior changed in 0.8.0.
    function _applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address) {
        unchecked {
            l2Address = address(uint160(l1Address) + uint160(0x1111000000000000000000000000000000001111));
        }
    }
}
