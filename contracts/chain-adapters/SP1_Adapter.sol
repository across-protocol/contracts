// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

contract DataStore {
    error NotHubPool();
    mapping(address => bytes) public dataForTarget;
    address public immutable hubPool;

    modifier onlyHubPool() {
        if (msg.sender != hubPool) {
            revert NotHubPool();
        }
        _;
    }

    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    function storeData(address target, bytes calldata data) external onlyHubPool {
        dataForTarget[target] = data;
    }
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using SP1 + Helios light clients.
 */
contract SP1_Adapter is AdapterInterface {
    DataStore public immutable DATA_STORE;

    constructor(DataStore _store) {
        DATA_STORE = _store;
    }

    /**
     * @notice Saves root bundle data in a simple storage contract that can be proven and relayed to L2.
     * @param target Contract on the destination that will receive the message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        DATA_STORE.storeData(target, abi.encode(address(this), target, message));
        emit MessageRelayed(target, message);
    }

    /**
     * @notice No-op relay tokens method.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        // This method is intentionally left as a no-op.
        // If the adapter is intended to be able to relay tokens, this method should be overridden.
    }
}
