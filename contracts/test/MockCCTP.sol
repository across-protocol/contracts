// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../libraries/CircleCCTPAdapter.sol";

contract MockCCTPMinter is ITokenMinter {
    function burnLimitsPerMessage(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}

contract MockCCTPMessenger is ITokenMessenger {
    ITokenMinter private minter;

    constructor(ITokenMinter _minter) {
        minter = _minter;
    }

    function depositForBurn(
        uint256,
        uint32,
        bytes32,
        address
    ) external pure returns (uint64 _nonce) {
        return 0;
    }

    function localMinter() external view returns (ITokenMinter) {
        return minter;
    }
}
