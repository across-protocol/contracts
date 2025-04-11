// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { HubPoolInterface } from "../../interfaces/HubPoolInterface.sol";

interface IHubPool {
    function rootBundleProposal() external view returns (HubPoolInterface.RootBundle memory);
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract. Each data to be
 * relayed is written to a unique slot key and that slot key's value can never be modified.
 * @dev Designed to be used with Universal_Adapter and Universal_SpokePool.
 * @dev This contract DOES NOT prevent replay attacks of storage proofs on the L2 spoke pool if the
 * UniversalStorageProof_Adapters using this contract are mapped to spokepools with the same address on different
 * L2 chains. See comment in storeRelayAdminFunctionCalldata() for more details.
 * @custom:security-contact bugs@across.to
 */
contract HubPoolStore {
    error NotHubPool();

    /// @notice Maps nonce to hash of calldata.
    mapping(uint256 => bytes32) public relayMessageCallData;

    /// @notice Counter to ensure that each relay admin function calldata is unique.
    uint256 private dataUuid;

    /// @notice Address of the HubPool contract, the only contract that can store data to this contract.
    address public immutable hubPool;

    /// @notice Event designed to be queried off chain and relayed to Universal SpokePool.
    event StoredCallData(address indexed target, bytes data, uint256 indexed nonce);

    modifier onlyHubPool() {
        if (msg.sender != hubPool) {
            revert NotHubPool();
        }
        _;
    }

    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    /**
     * @notice To be called by HubPool to store calldata that will be relayed
     * to the Universal_SpokePool via storage proofs.
     * @dev Only callable by the HubPool contract.
     * @param target Address of the contract on the destination that will receive the message. Unused if the
     * data is NOT an admin function and can be relayed to any target.
     * @param data Data to send to Universal SpokePool.
     * @param isAdminSender True if the data is an admin function call, false otherwise.
     */
    function storeRelayMessageCalldata(
        address target,
        bytes calldata data,
        bool isAdminSender
    ) external onlyHubPool {
        if (isAdminSender) {
            _storeData(target, dataUuid++, data);
        } else {
            _storeRelayMessageCalldataForAnyTarget(data);
        }
    }

    function _storeRelayMessageCalldataForAnyTarget(bytes calldata data) internal {
        // When the data can be sent to any target, we assume that the data contains a relayRootBundleCall as
        // constructed by an executeRootBundle() call, therefore this data will be identical for all spoke pools
        // in this bundle. We can use the current hub pool's challengePeriodEndTimestamp as the nonce for this data
        // so that all relayRootBundle calldata for this bundle gets stored to the same slot and we only write to
        // this slot once.
        _storeData(address(0), IHubPool(hubPool).rootBundleProposal().challengePeriodEndTimestamp, data);
    }

    function _storeData(
        address target,
        uint256 nonce,
        bytes calldata data
    ) internal {
        if (relayMessageCallData[nonce] != bytes32(0)) {
            // Data is already stored, do nothing.
            return;
        }
        relayMessageCallData[nonce] = keccak256(abi.encode(target, data));
        emit StoredCallData(target, data, nonce);
    }
}
