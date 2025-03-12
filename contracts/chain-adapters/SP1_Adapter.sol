// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

/**
 * @notice Stores data that can be relayed to L2 SpokePool using SP1 + Helios light clients. Only the HubPool
 * can store data.
 */
contract HubPoolStore {
    error NotHubPool();

    struct Data {
        bytes data;
        address target;
        uint256 nonce;
    }
    // Mapping from data hash to unique data.
    mapping(bytes32 => Data) public storedData;

    // Counter to ensure that each stored data is unique.
    uint256 private dataUuid;

    address public immutable hubPool;

    event StoredDataForTarget(bytes32 dataHash, address indexed target, bytes data, uint256 uuid);

    modifier onlyHubPool() {
        if (msg.sender != hubPool) {
            revert NotHubPool();
        }
        _;
    }

    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    function storeDataForTarget(address target, bytes calldata data) external onlyHubPool {
        uint256 nonce = dataUuid++;
        _storeData(target, data, nonce);
    }

    function storeDataForTargetWithNonce(
        address target,
        bytes calldata data,
        uint256 nonce
    ) external onlyHubPool {
        _storeData(target, data, nonce);
    }

    function _storeData(
        address target,
        bytes calldata data,
        uint256 nonce
    ) internal {
        Data memory newData = Data({ data: data, target: target, nonce: nonce });
        bytes32 dataHash = keccak256(abi.encode(newData));
        if (storedData[dataHash].data.length > 0) {
            // Data is already stored, do nothing.
            return;
        }
        storedData[dataHash] = newData;
        emit StoredDataForTarget(dataHash, target, data, nonce);
    }
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using SP1 + Helios light clients.
 */
contract SP1_Adapter is AdapterInterface {
    HubPoolStore public immutable DATA_STORE;

    error NotImplemented();

    constructor(HubPoolStore _store) {
        DATA_STORE = _store;
    }

    /**
     * @notice Saves root bundle data in a simple storage contract that can be proven and relayed to L2.
     * @param target Contract on the destination that will receive the message.
     * @param message Data to send to target.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        bytes4 selector = bytes4(message[:4]);
        if (selector == SpokePoolInterface.relayRootBundle.selector) {
            // Check if the message contains a relayRootBundle() call for the target SpokePool. If so, then
            // store the data without a specific target in-mind and hardcode nonce.
            // This is a gas optimization so that we only update a
            // storage slot in the HubPoolStore once per root bundle execution, since the data passed to relayRootBundle
            // will be the same for all chains. We are assuming therefore that the relayerRefundRoot and slowRelayRoot
            // combination are never repeated for a root bundle.
            DATA_STORE.storeDataForTargetWithNonce(address(0), message, 0);
        } else {
            // Because we do not have the chain ID where the target is deployed, we can only associate this message
            // with the target address. Therefore we are assuming that target spoke pool addresses are unique across
            // chains.
            DATA_STORE.storeDataForTarget(target, message);
        }

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
        // If the adapter is intended to be able to relay tokens, this method should be overridden.
        revert NotImplemented();
    }
}
