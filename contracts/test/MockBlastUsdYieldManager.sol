// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { USDYieldManager } from "../Blast_DaiRetriever.sol";

contract MockBlastUsdYieldManager is USDYieldManager {
    bool public shouldFail;

    constructor() {
        shouldFail = false;
    }

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function claimWithdrawal(uint256 _requestId, uint256 _hintId) external returns (bool success) {
        success = !shouldFail;
    }
}
