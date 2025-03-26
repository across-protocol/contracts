// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolInterface } from "../../interfaces/HubPoolInterface.sol";

interface IHubPool {
    function rootBundleProposal() external view returns (HubPoolInterface.RootBundle memory);
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract.
 * @dev Designed to be used with UniversalStorageProof_Adapter and UniversalStorageProof_SpokePool.
 */
contract HubPoolStore {
    error NotHubPool();

    // Maps unique calldata hashes to calldata.
    mapping(bytes32 => bytes) public relayAdminFunctionCalldata;

    // Counter to ensure that each relay admin function calldata is unique.
    uint256 private dataUuid;

    // Address of the HubPool contract, the only contract that can store data to this contract.
    address public immutable hubPool;

    event StoredAdminFunctionData(bytes32 dataHash, address indexed target, bytes data, uint256 uuid, bytes slotValue);

    modifier onlyHubPool() {
        if (msg.sender != hubPool) {
            revert NotHubPool();
        }
        _;
    }

    /**
     * @notice Constructor.
     * @param _hubPool Address of the HubPool contract.
     */
    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    /**
     * @notice To be called by HubPool to store calldata for any relay admin function except relayRootBundle.
     * This function is expected to be called less frequently than storeRelayRootsCalldata and each call gets
     * a unique nonce to prevent replay attacks on the L2 spoke pool.
     * @dev Only callable by the HubPool contract.
     * @param target Address of the contract on the destination that will receive the message.
     * @param data Data to send to target.
     */
    function storeRelayAdminFunctionCalldata(address target, bytes calldata data) external onlyHubPool {
        uint256 nonce = dataUuid++;
        // Because we do not have the chain ID where the target is deployed, we can only associate this message
        // with the target address. Therefore we are assuming that target spoke pool addresses are unique across
        // chains. This technically doesn't prevent replay attacks where two spokes on different chains have
        // the same address, but one way to prevent that is to deploy this store once per different L2 chain
        // The L2's storage proof verification would only validate storage slots on this specific contract deployment.
        _storeData(target, nonce, data);
    }

    /**
     * @notice To be called by HubPool to store calldata for the relayRootBundle function. This function is a special
     * case that is expected to be called once per L2 spoke pool using this adapter with the same calldata. Therefore,
     * it is a gas optimization to call this function instead of storeRelayAdminFunctionCalldata because this function
     * will only write a storage slot one per root bundle.
     * @dev Only callable by the HubPool contract.
     * @param target Address of the contract on the destination that will receive the message.
     * @param data Data to send to target.
     */
    function storeRelayRootsCalldata(address target, bytes calldata data) external onlyHubPool {
        // There is a rare case where the roots are being relayed outside of the normal root bundle
        // proposal-liveness-execution process, so in this case we'll use the global nonce.
        // We also use the actual target in this case since an admin bundle is destined for a specific spoke.
        HubPoolInterface.RootBundle memory pendingRootBundle = IHubPool(hubPool).rootBundleProposal();
        // We are assuming that the root bundle being relayed is an admin root bundle if there is either no
        // pending root bundle or the pending refund and slow roots are equal to the roots being relayed. We cannot
        // distinguish the case where the admin root bundle is the same as the pending root bundle, which seems
        // extremely unlikely so we're going to ignore it. If this does happen, the adapter can be redeployed to point
        // to a new HubPoolStore, and the corresponding spoke pool should also be redeployed to point to the new
        // HubPoolStore.
        bool isAdminRootBundle = keccak256(
            abi.encodeWithSignature(
                "relayRootBundle(bytes32,bytes32)",
                pendingRootBundle.relayerRefundRoot,
                pendingRootBundle.slowRelayRoot
            )
        ) != keccak256(data);
        if (isAdminRootBundle) {
            uint256 nonce = dataUuid++;
            _storeData(target, nonce, data);
        } else {
            // Use pending root bundle challenge period timestamp as the unique nonce, so we only store this slot once
            // per root bundle execution. We also hardcode the target address to be 0.
            uint256 nonce = IHubPool(hubPool).rootBundleProposal().challengePeriodEndTimestamp;
            _storeData(address(0), nonce, data);
        }
    }

    function _storeData(
        address target,
        uint256 nonce,
        bytes calldata data
    ) internal {
        bytes32 dataHash = keccak256(abi.encode(target, data, nonce));
        if (relayAdminFunctionCalldata[dataHash].length > 0) {
            // Data is already stored, do nothing.
            return;
        }
        bytes memory callDataToStore = abi.encode(target, data);
        relayAdminFunctionCalldata[dataHash] = abi.encode(target, data);
        emit StoredAdminFunctionData(dataHash, target, data, nonce, callDataToStore);
    }
}
