// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "../libraries/CircleCCTPAdapter.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";
import { HubPoolInterface } from "../interfaces/HubPoolInterface.sol";

interface IHubPool {
    function rootBundleProposal() external view returns (HubPoolInterface.RootBundle memory);
}

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed. Only the HubPool can store data to this contract.
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
        // extremely unlikely so we're going to ignore it.
        bool isAdminRootBundle = pendingRootBundle.challengePeriodEndTimestamp == 0 ||
            keccak256(
                abi.encodeWithSignature(
                    "relayRootBundle(bytes32,bytes32)",
                    pendingRootBundle.relayerRefundRoot,
                    pendingRootBundle.slowRelayRoot
                )
            ) !=
            keccak256(data);
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

/**
 * @notice Stores data that can be relayed to L2 SpokePool using storage proof verification and light client contracts
 * on the L2 where the SpokePool is deployed.
 * @dev This contract should NOT be reused to send messages to SpokePools that have the same address on different L2s.
 * @dev This contract should be CAREFULLY used when relaying admin root bundles to SpokePools and should NOT be used
 * if the admin root bundle's relayerRefundRoot and slowRelayRoots are identical to a pending root bundle proposal.
 */
contract UniversalStorageProof_Adapter is AdapterInterface, CircleCCTPAdapter {
    // Contract on which to write calldata to be relayed to L2 via storage proofs.
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
     * @dev Uses gas optimized function to write root bundle data to be relayed to all L2 spoke pools.
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
            DATA_STORE.storeRelayRootsCalldata(target, message);
        } else {
            DATA_STORE.storeRelayAdminFunctionCalldata(target, message);
        }

        emit MessageRelayed(target, message);
    }

    /**
     * @notice Relays tokens from L1 to L2.
     * @dev This function only uses the CircleCCTPAdapter to relay USDC tokens to CCTP enabled L2 chains.
     * Relaying other tokens will cause this function to revert.
     * @param l1Token Address of the token on L1.
     * @param l2Token Address of the token on L2.
     * @param amount Amount of tokens to relay.
     * @param to Address to receive the tokens on L2. Should be SpokePool address.
     */
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
