// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { SpokePoolInterface } from "../interfaces/SpokePoolInterface.sol";

import "../libraries/CircleCCTPAdapter.sol";

/**
 * @notice Adapter to be used to relay messages to L2 SpokePools that have light client and verification contracts
 * that can verify event inclusion proofs.
 */
contract UniversalEventInclusionProof_Adapter is AdapterInterface, CircleCCTPAdapter {
    error NotImplemented();

    event RelayedMessage(address indexed target, bytes message);

    constructor(
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _cctpDestinationDomainId
    ) CircleCCTPAdapter(_l1Usdc, _cctpTokenMessenger, _cctpDestinationDomainId) {}

    /**
     * @notice Emits an event containing the message that we can submit to the target spoke pool via
     * event inclusion proof.
     */
    function relayMessage(address target, bytes calldata message) external payable override {
        emit RelayedMessage(target, message);
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
