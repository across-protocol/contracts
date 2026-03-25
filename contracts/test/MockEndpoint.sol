// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IEndpoint } from "../interfaces/IOFT.sol";

contract MockEndpoint is IEndpoint {
    uint32 internal _eid;

    constructor(uint32 eid_) {
        _eid = eid_;
    }

    function eid() external view override returns (uint32) {
        return _eid;
    }
}
