// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "../libraries/CircleCCTPAdapter.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract.
 */
contract HubPoolStore {
    error NotHubPool();

    // Maps unique calldata hashes to calldata.
    mapping(bytes32 => bytes) public relayAdminFunctionCalldata;

    // Stores latest relayRoots calldata.
    bytes public latestRelayRootsCalldata;

    // Counter to ensure that each stored data is unique.
    uint256 private dataUuid;

    // Address of the HubPool contract, the only contract that can store data to this contract.
    address public immutable hubPool;

    event StoredAdminFunctionData(bytes32 dataHash, address indexed target, bytes data, uint256 uuid);
    event StoredRootBundleData(bytes data);

    modifier onlyHubPool() {
        if (msg.sender != hubPool) {
            revert NotHubPool();
        }
        _;
    }

    constructor(address _hubPool) {
        hubPool = _hubPool;
    }

    function storeRelayAdminFunctionCalldata(address target, bytes calldata data) external onlyHubPool {
        uint256 nonce = dataUuid++;
        // Because we do not have the chain ID where the target is deployed, we can only associate this message
        // with the target address. Therefore we are assuming that target spoke pool addresses are unique across
        // chains. This technically doesn't prevent replay attacks where two spokes on different chains have
        // the same address, but one way to prevent that is to deploy this store once per different L2 chain
        // The L2's storage proof verification would only validate storage slots on this specific contract deployment.
        bytes32 dataHash = keccak256(abi.encode(target, data, nonce));
        if (relayAdminFunctionCalldata[dataHash].length > 0) {
            // Data is already stored, do nothing.
            return;
        }
        relayAdminFunctionCalldata[dataHash] = abi.encode(target, data);
        emit StoredAdminFunctionData(dataHash, target, data, nonce);
    }

    function storeRelayRootsCalldata(bytes calldata data) external onlyHubPool {
        // calldata should always be the same length so we can't optimize by checking length first.
        if (keccak256(data) == keccak256(latestRelayRootsCalldata)) {
            // Data is already stored, do nothing.
            return;
        }
        latestRelayRootsCalldata = data;
        emit StoredRootBundleData(data);
    }
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed.
 */
contract UniversalStorageProof_Adapter is AdapterInterface, CircleCCTPAdapter {
    HubPoolStore public immutable DATA_STORE;

    error NotImplemented();

    constructor(
        HubPoolStore _store,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _cctpDestinationDomainId
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, _cctpDestinationDomainId) {
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
            // If the message contains a relayRootBundle() call for the target SpokePool, then
            // store the data without a specific target in-mind. This is a gas optimization so that we only update a
            // storage slot in the HubPoolStore once per root bundle execution, since the data passed to relayRootBundle
            // will be the same for all chains.
            DATA_STORE.storeRelayRootsCalldata(message);
        } else {
            DATA_STORE.storeRelayAdminFunctionCalldata(target, message);
        }

        emit MessageRelayed(target, message);
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override {
        if (_isCCTPEnabled() && l1Token == address(usdcToken)) {
            _transferUsdc(to, amount);
        } else {
            revert NotImplemented();
        }
    }
}
