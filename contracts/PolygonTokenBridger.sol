// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "./Lockable.sol";
import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Polygon Registry contract that stores their addresses.
interface PolygonRegistry {
    function erc20Predicate() external returns (address);
}

// Polygon ERC20Predicate contract that handles Plasma exits (only used for Matic).
interface PolygonERC20Predicate {
    function startExitWithBurntTokens(bytes calldata data) external;
}

// ERC20s (on polygon) compatible with polygon's bridge have a withdraw method.
interface PolygonIERC20 is IERC20 {
    function withdraw(uint256 amount) external;
}

interface MaticToken {
    function withdraw(uint256 amount) external payable;
}

/**
 * @notice Contract deployed on Ethereum and Polygon to facilitate token transfers from Polygon to the HubPool and back.
 * @dev Because Polygon only allows withdrawals from a particular address to go to that same address on mainnet, we need to
 * have some sort of contract that can guarantee identical addresses on Polygon and Ethereum. This contract is intended
 * to be completely immutable, so it's guaranteed that the contract on each side is  configured identically as long as
 * it is created via create2. create2 is an alternative creation method that uses a different address determination
 * mechanism from normal create.
 * Normal create: address = hash(deployer_address, deployer_nonce)
 * create2:       address = hash(0xFF, sender, salt, bytecode)
 *  This ultimately allows create2 to generate deterministic addresses that don't depend on the transaction count of the
 * sender.
 */
contract PolygonTokenBridger is Lockable {
    using SafeERC20 for PolygonIERC20;
    using SafeERC20 for IERC20;

    // Gas token for Polygon.
    MaticToken public constant maticToken = MaticToken(0x0000000000000000000000000000000000001010);

    // Should be set to HubPool on Ethereum, or unused on Polygon.
    address public immutable destination;

    // Registry that stores L1 polygon addresses.
    PolygonRegistry public immutable l1PolygonRegistry;

    // WETH contract on Ethereum.
    WETH9 public immutable l1Weth;

    // Wrapped Matic on Polygon
    address public immutable l2WrappedMatic;

    // Chain id for the L1 that this contract is deployed on or communicates with.
    // For example: if this contract were meant to facilitate transfers from polygon to mainnet, this value would be
    // the mainnet chainId 1.
    uint256 public immutable l1ChainId;

    // Chain id for the L2 that this contract is deployed on or communicates with.
    // For example: if this contract were meant to facilitate transfers from polygon to mainnet, this value would be
    // the polygon chainId 137.
    uint256 public immutable l2ChainId;

    modifier onlyChainId(uint256 chainId) {
        _requireChainId(chainId);
        _;
    }

    /**
     * @notice Constructs Token Bridger contract.
     * @param _destination Where to send tokens to for this network.
     * @param _l1PolygonRegistry L1 registry that stores updated addresses of polygon contracts. This should always be
     * set to the L1 registry regardless if whether it's deployed on L2 or L1.
     * @param _l1Weth L1 WETH address.
     * @param _l1ChainId the chain id for the L1 in this environment.
     * @param _l2ChainId the chain id for the L2 in this environment.
     */
    constructor(
        address _destination,
        PolygonRegistry _l1PolygonRegistry,
        WETH9 _l1Weth,
        address _l2WrappedMatic,
        uint256 _l1ChainId,
        uint256 _l2ChainId
    ) {
        destination = _destination;
        l1PolygonRegistry = _l1PolygonRegistry;
        l1Weth = _l1Weth;
        l2WrappedMatic = _l2WrappedMatic;
        l1ChainId = _l1ChainId;
        l2ChainId = _l2ChainId;
    }

    /**
     * @notice Called by Polygon SpokePool to send tokens over bridge to contract with the same address as this.
     * @notice The caller of this function must approve this contract to spend amount of token.
     * @param token Token to bridge.
     * @param amount Amount to bridge.
     */
    function send(PolygonIERC20 token, uint256 amount) public nonReentrant onlyChainId(l2ChainId) {
        token.safeTransferFrom(msg.sender, address(this), amount);

        // In the wMatic case, this unwraps. For other ERC20s, this is the burn/send action.
        token.withdraw(token.balanceOf(address(this)));

        // This takes the token that was withdrawn and calls withdraw on the "native" ERC20.
        if (address(token) == l2WrappedMatic)
            maticToken.withdraw{ value: address(this).balance }(address(this).balance);
    }

    /**
     * @notice Called by someone to send tokens to the destination, which should be set to the HubPool.
     * @param token Token to send to destination.
     */
    function retrieve(IERC20 token) public nonReentrant onlyChainId(l1ChainId) {
        if (address(token) == address(l1Weth)) {
            // For WETH, there is a pre-deposit step to ensure any ETH that has been sent to the contract is captured.
            l1Weth.deposit{ value: address(this).balance }();
        }
        token.safeTransfer(destination, token.balanceOf(address(this)));
    }

    /**
     * @notice Called to initiate an l1 exit (withdrawal) of matic tokens that have been sent over the plasma bridge.
     * @param data the proof data to trigger the exit. Can be generated using the maticjs-plasma package.
     */
    function callExit(bytes memory data) public nonReentrant onlyChainId(l1ChainId) {
        PolygonERC20Predicate erc20Predicate = PolygonERC20Predicate(l1PolygonRegistry.erc20Predicate());
        erc20Predicate.startExitWithBurntTokens(data);
    }

    receive() external payable {
        // This method is empty to avoid any gas expendatures that might cause transfers to fail.
        // Note: the fact that there is _no_ code in this function means that matic can be erroneously transferred in
        // to the contract on the polygon side. These tokens would be locked indefinitely since the receive function
        // cannot be called on the polygon side. While this does have some downsides, the lack of any functionality
        // in this function means that it has no chance of running out of gas on transfers, which is a much more
        // important benefit. This just makes the matic token risk similar to that of ERC20s that are erroneously
        // sent to the contract.
    }

    function _requireChainId(uint256 chainId) internal view {
        require(block.chainid == chainId, "Cannot run method on this chain");
    }
}
