// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "../libraries/OFTTransportAdapter.sol";
import { AdapterStore } from "../libraries/AdapterStore.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract.
 */
contract HubPoolStore {
    error NotHubPool();

    // Maps unique data hashes to data to relay to target.
    mapping(bytes32 => bytes) public storedData;

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
        bytes32 dataHash = keccak256(abi.encode(target, data, nonce));
        if (storedData[dataHash].length > 0) {
            // Data is already stored, do nothing.
            return;
        }
        storedData[dataHash] = abi.encode(target, data);
        emit StoredDataForTarget(dataHash, target, data, nonce);
    }
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed.
 */
contract UniversalStorageProof_Adapter is AdapterInterface, OFTTransportAdapter {
    HubPoolStore public immutable DATA_STORE;

    // Chain id of the chain this adapter helps bridge to.
    uint256 public immutable DESTINATION_CHAIN_ID;

    // Helper storage contract to support bridging via differnt token standards: OFT, XERC20
    AdapterStore public immutable ADAPTER_STORE;

    error NotImplemented();

    constructor(
        HubPoolStore _store,
        address _adapterStore,
        uint256 _dstChainId,
        uint32 _oftDstEid,
        uint256 _oftFeeCap
    ) OFTTransportAdapter(_oftDstEid, _oftFeeCap) {
        DATA_STORE = _store;
        DESTINATION_CHAIN_ID = _dstChainId;
        ADAPTER_STORE = AdapterStore(_adapterStore);
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

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        address oftMessenger = _getOftMessenger(l1Token);
        if (oftMessenger != address(0)) {
            _transferViaOFT(IERC20(l1Token), IOFT(oftMessenger), to, amount);
        } else {
            revert NotImplemented();
        }
    }

    function _getOftMessenger(address _token) internal view returns (address) {
        return ADAPTER_STORE.oftMessengers(DESTINATION_CHAIN_ID, _token);
    }
}
