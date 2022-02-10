// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;
import "../interfaces/AdapterInterface.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

abstract contract Base_Adapter is Ownable, AdapterInterface {
    address public hubPool;

    modifier onlyHubPool() {
        require(msg.sender == hubPool, "Can only be called by hubPool");
        _;
    }

    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    function setHubPool(address _hubPool) public onlyOwner {
        hubPool = _hubPool;
        emit HubPoolChanged(_hubPool);
    }
}
