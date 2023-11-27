// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./external/interfaces/SuccinctInterfaces.sol";

/**
 * @notice Succinct Spoke pool.
 */
contract Succinct_SpokePool is SpokePool, ITelepathyHandler {
    // Address of the succinct AMB contract.
    address public succinctTargetAmb;

    // Chain where HubPool is deployed that is linked to this SpokePool.
    uint16 public hubChainId;

    // Warning: this variable should _never_ be touched outside of this contract. It is intentionally set to be
    // private. Leaving it set to true can permanently disable admin calls.
    bool private adminCallValidated;

    event SetSuccinctTargetAmb(address indexed newSuccinctTargetAmb);
    event ReceivedMessageFromL1(address indexed caller, address indexed rootMessageSender);

    // Note: validating calls this way ensures that strange calls coming from the succinctTargetAmb won't be
    // misinterpreted. Put differently, just checking that msg.sender == succinctTargetAmb is not sufficient.
    // All calls that have admin privileges must be fired from within the handleTelepathy method that's gone
    // through validation where the sender is checked and the sender from the other chain is also validated.
    // This modifier sets the adminCallValidated variable so this condition can be checked in _requireAdminSender().
    modifier validateInternalCalls() {
        // Make sure adminCallValidated is set to True only once at beginning of processMessageFromRoot, which prevents
        // processMessageFromRoot from being re-entered.
        require(!adminCallValidated, "adminCallValidated already set");

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed.
        adminCallValidated = true;

        _;

        // Reset adminCallValidated to false to disallow admin calls after this method exits.
        adminCallValidated = false;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the Succinct SpokePool.
     * @param _hubChainId Chain ID of the chain where the HubPool is deployed.
     * @param _succinctTargetAmb Address of the succinct AMB contract.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        uint16 _hubChainId,
        address _succinctTargetAmb,
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        succinctTargetAmb = _succinctTargetAmb;
        hubChainId = _hubChainId;
    }

    /**
     * @notice Admin can reset the succinct contract address.
     * @param _succinctTargetAmb Address of the succinct AMB contract.
     */
    function setSuccinctTargetAmb(address _succinctTargetAmb) external onlyAdmin {
        succinctTargetAmb = _succinctTargetAmb;
        emit SetSuccinctTargetAmb(_succinctTargetAmb);
    }

    /**
     * @notice This will be called by Succinct AMB on this network to relay a message sent from the HubPool.
     * @param _sourceChainId Chain ID of the chain where the message originated.
     * @param _senderAddress Address of the sender on the chain where the message originated.
     * @param _data Data to be received and executed on this contract.
     */
    function handleTelepathy(
        uint16 _sourceChainId,
        address _senderAddress,
        bytes memory _data
    ) external override validateInternalCalls returns (bytes4) {
        // Validate msg.sender as succinct, the x-chain sender as being the hubPool (the admin) and the source chain as
        // 1 (mainnet).
        require(msg.sender == succinctTargetAmb, "caller not succinct AMB");
        require(_senderAddress == hubPool, "sender not hubPool");
        require(_sourceChainId == hubChainId, "source chain not hub chain");

        /// @custom:oz-upgrades-unsafe-allow delegatecall
        (bool success, ) = address(this).delegatecall(_data);
        require(success, "delegatecall failed");

        emit ReceivedMessageFromL1(msg.sender, _senderAddress);
        return ITelepathyHandler.handleTelepathy.selector;
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
