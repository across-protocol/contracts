// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./interfaces/WETH9Interface.sol";
import "./external/SuccinctInterfaces.sol";

contract Succinct_SpokePool is SpokePool, ITelepathyHandler {
    // Address of the succinct contract.
    address public succinctTargetAmb;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private adminCallValidated;

    uint16 public hubChainId;

    // Note: validating calls this way ensures that strange calls coming from the succinctTargetAmb won't be misinterpreted.
    // Put differently, just checking that msg.sender == succinctTargetAmb is not sufficient.
    // All calls that have admin privileges must be fired from within the handleTelepathy method that's gone
    // through validation where the sender is checked and the sender from the other chain is also validated.
    // This modifier sets the callValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure callValidated is set to True only once at beginning of processMessageFromRoot, which prevents
        // processMessageFromRoot from being re-entered.
        require(!adminCallValidated, "adminCallValidated already set");

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed.
        adminCallValidated = true;

        _;

        // Reset callValidated to false to disallow admin calls after this method exits.
        adminCallValidated = false;
    }

    function initialize(
        uint16 _hubChainId,
        address _succinctTargetAmb,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        address _wrappedNativeToken,
        address timerAddress
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, _wrappedNativeToken, timerAddress);
        succinctTargetAmb = _succinctTargetAmb;
        hubChainId = _hubChainId;
    }

    // Admin can reset the succinct contract address.
    function setSuccinctTargetAmb(address _succinctTargetAmb) external onlyAdmin {
        succinctTargetAmb = _succinctTargetAmb;
    }

    function handleTelepathy(
        uint16 _sourceChainId,
        address _senderAddress,
        bytes memory _data
    ) external override validateInternalCalls {
        // Validate msg.sender as succinct, the x-chain sender as being the hubPool (the admin) and the source chain as
        // 1 (mainnet).
        require(
            msg.sender == succinctTargetAmb && _senderAddress == hubPool && _sourceChainId == hubChainId,
            "Invalid message"
        );

        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_data);
        require(success, "delegatecall failed");
    }

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory) internal override {
        // This method is a no-op. If the chain intends to include bridging functionality, this must be overriden.
        // If not, leaving this unimplemented means this method may be triggered, but the result will be that no
        // balance is transferred.
    }

    // Check that the handleTelepathy method has validated the method to ensure the sender is authenticated.
    function _requireAdminSender() internal view override {
        require(adminCallValidated, "Admin call not validated");
    }
}
