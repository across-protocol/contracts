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
    ) external override {
        // Validate msg.sender as succinct, the x-chain sender as being the hubPool (the admin) and the source chain as
        // 1 (mainnet).
        require(
            msg.sender == succinctTargetAmb && _senderAddress == hubPool && _sourceChainId == hubChainId,
            "Invalid message"
        );

        // This operates similarly to a re-entrancy guard. It is set after validation to tell methods called by this
        // method that the call has been validated as an admin and is safe.
        require(!adminCallValidated, "Re-entered handleTelepathy");
        adminCallValidated = true;

        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_data);
        require(success, "delegatecall failed");

        // Reset to false before returning to ensure no calls outside of the delegatecall above can assume admin priviledges.
        adminCallValidated = false;
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
