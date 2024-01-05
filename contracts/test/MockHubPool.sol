// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title MockHubPool for Token Relay between Layer 1 and Layer 2
/// @dev This contract acts as a mock implementation for testing purposes,
///      simulating the behavior of a hub pool that can relay tokens and messages
///      between Ethereum (Layer 1) and a Layer 2 solution like Optimism.
///      It delegates calls to an external chain adapter contract for actual execution.
contract MockHubPool {
    /// @notice Emitted when the adapter contract address is changed.
    event AdapterChanged(address indexed oldAdapter, address indexed newAdapter);

    /// @notice The address of the contract owner, set to the deployer of the contract.
    address public immutable owner;
    /// @notice The address of the adapter contract responsible for handling
    ///         token relay and message passing to Layer 2.
    address public adapter;

    /// @notice Creates a new MockHubPool and sets the owner and initial adapter.
    /// @param _adapter The address of the initial adapter contract.
    constructor(address _adapter) {
        adapter = _adapter;
        owner = msg.sender; // Set the contract deployer as the owner
    }

    /// @notice Ensures that a function is callable only by the contract owner.
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    /// @notice Fallback function to receive ETH.
    fallback() external payable {} // solhint-disable-line no-empty-blocks

    /// @notice Receive function to handle direct ETH transfers.
    receive() external payable {} // solhint-disable-line no-empty-blocks

    /// @notice Changes the adapter contract address.
    /// @dev This function can only be called by the contract owner.
    /// @param _adapter The new adapter contract address.
    function changeAdapter(address _adapter) public onlyOwner {
        require(_adapter != address(0), "NO_ZERO_ADDRESS");
        address _oldAdapter = adapter;
        adapter = _adapter;
        emit AdapterChanged(_oldAdapter, _adapter);
    }

    /// @notice Relays tokens from L1 to L2 using the adapter contract.
    /// @dev This function delegates the call to the adapter contract.
    /// @param l1Token The address of the L1 token to relay.
    /// @param l2Token The address of the L2 token to receive.
    /// @param amount The amount of tokens to relay.
    /// @param to The address on L2 to receive the tokens.
    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external {
        (bool success, ) = adapter.delegatecall(
            abi.encodeWithSignature(
                "relayTokens(address,address,uint256,address)",
                l1Token, // l1Token.
                l2Token, // l2Token.
                amount, // amount.
                to // to. This should be the spokePool.
            )
        );
        require(success, "delegatecall failed");
    }

    /// @notice Queries the balance of a user for a specific L2 token using the adapter contract.
    /// @dev This function delegates the call to the adapter contract to execute the balance check.
    /// @param l2Token The address of the L2 token.
    /// @param user The user address whose balance is being queried.
    function balanceOf(address l2Token, address user) external {
        (bool success, ) = adapter.delegatecall(
            abi.encodeWithSignature(
                "relayMessage(address,bytes)",
                l2Token,
                abi.encodeWithSignature("balanceOf(address)", user) // message
            )
        );
        require(success, "delegatecall failed");
    }

    /// @notice Relays an arbitrary message to the L2 chain via the adapter contract.
    /// @dev This function delegates the call to the adapter contract to execute the message relay.
    /// @param target The address of the target contract on L2.
    /// @param l2CallData The calldata to send to the target contract on L2. (must be abi encoded)
    function arbitraryMessage(address target, bytes memory l2CallData) external {
        (bool success, ) = adapter.delegatecall(
            abi.encodeWithSignature("relayMessage(address,bytes)", target, l2CallData)
        );
        require(success, "delegatecall failed");
    }
}
