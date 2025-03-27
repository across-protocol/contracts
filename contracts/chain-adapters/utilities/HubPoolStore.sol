// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolInterface } from "../../interfaces/HubPoolInterface.sol";

interface IHubPool {
    function rootBundleProposal() external view returns (HubPoolInterface.RootBundle memory);
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract. Each data to be
 * relayed is written to a unique slot key and that slot key's value can never be changed or deleted.
 * @dev Designed to be used with UniversalStorageProof_Adapter and UniversalStorageProof_SpokePool.
 * @dev This contract DOES NOT prevent replay attacks of storage proofs on the L2 spoke pool if the
 * UniversalStorageProof_Adapters using this contract are mapped to spokepools with the same address on different
 * L2 chains. See comment in storeRelayAdminFunctionCalldata() for more details.
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
     * @notice To be called by HubPool to store calldata for any relay admin function to
     * be relayed to the UniversalStorageProof_SpokePool via storage proofs.
     * Each call gets a unique nonce to prevent replay attacks on the L2 spoke pool.
     * @dev Only callable by the HubPool contract.
     * @param target Address of the contract on the destination that will receive the message.
     * @param data Data to send to target.
     */
    function storeRelayAdminFunctionCalldata(address target, bytes calldata data) external onlyHubPool {
        // Because we do not have the chain ID where the target is deployed, we can only associate this message
        // with the target address. Therefore we are assuming that target spoke pool addresses are unique across
        // chains. This technically doesn't prevent replay attacks where two spokes on different chains have
        // the same address, but one way to prevent that is to deploy this store once per different L2 chain
        // The L2's storage proof verification would only validate storage slots on this specific contract deployment.
        _storeData(target, dataUuid++, data);
    }

    /**
     * @notice To be called by HubPool to store calldata for the relayRootBundle function that will be relayed
     * to the UniversalStorageProof_SpokPool via storage proofs. This function is a special
     * case that is expected to be called once per L2 spoke pool using this adapter with the same calldata. Therefore,
     * it is a gas optimization to call this function instead of storeRelayAdminFunctionCalldata because this function
     * will only write a storage slot once per executed root bundle.
     * @dev Only callable by the HubPool contract.
     * @param target Address of the contract on the destination that will receive the message.
     * @param data Data to send to target.
     */
    function storeRelayRootsCalldata(address target, bytes calldata data) external onlyHubPool {
        HubPoolInterface.RootBundle memory pendingRootBundle = IHubPool(hubPool).rootBundleProposal();
        // We need to know whether the data contains an admin or a normal relayRootBundle call in order to set the
        // target and the nonce correctly in the data hash. The target cannot be set to address(0) for an admin bundle
        // because then the admin bundle could be replayed on any spoke pool, and we should use the global nonce
        // like other admin functions. Therefore, we check whether there is a pending bundle that hasn't passed
        // liveness yet, or there is no bundle proposed. In these two cases, it is impossible for the HubPool
        // to attempt to relay a root bundle unless it is relaying an admin bundle. In the third case where
        // the pending bundle has passed liveness, we check whether the data is the same as the pending bundle
        // to determine whether it is an admin bundle or not, as a final check.
        bool isAdminRootBundle = pendingRootBundle.challengePeriodEndTimestamp > block.timestamp ||
            pendingRootBundle.challengePeriodEndTimestamp == 0 ||
            keccak256(
                abi.encodeWithSignature(
                    "relayRootBundle(bytes32,bytes32)",
                    pendingRootBundle.relayerRefundRoot,
                    pendingRootBundle.slowRelayRoot
                )
            ) !=
            keccak256(data);
        if (isAdminRootBundle) {
            _storeData(target, dataUuid++, data);
        } else {
            // @dev WARNING: We can still enter this block for an admin root bundle if it is being sent after the
            // pending root bundle has passed liveness but not been executed yet AND the admin root bundle
            // has the same calldata as the normal root bundle. This is a really rare case and there shouldn't
            // be any repercussions besides the admin root bundle having zero effect on the spoke pools, since the
            // calldata will be relayed to all spoke pools regardless.

            // Normal expected use case of this function is to send a relayRootBundle() call to all spoke pools
            // using this adapter after a successful executed root bundle proposal. Importantly, all of these
            // root bundles have the same calldata, so we only need to update the storage slot once per
            // root bundle execution. We do this by hardcoding the target address and nonce to be the same for
            // all relayRootBundle() calls for this bundle execution. THe UniversalStorageProof_SpokePool that will
            // read storage from this contract via storage proofs is aware of the zero address being hardcoded
            // for relayRootBundle() calls in this case.
            _storeData(address(0), IHubPool(hubPool).rootBundleProposal().challengePeriodEndTimestamp, data);
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
