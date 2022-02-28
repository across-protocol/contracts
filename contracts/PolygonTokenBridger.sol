// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Lockable.sol";
import "./interfaces/WETH9.sol";

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

    // WETH contract on Ethereum.
    WETH9 public immutable l1Weth;

    /**
     * @notice Constructs Token Bridger contract.
     * @param _destination Where to send tokens to for this network.
     * @param _l1Weth Ethereum WETH address.
     */
    constructor(address _destination, WETH9 _l1Weth) {
        destination = _destination;
        l1Weth = _l1Weth;
    }

    /**
     * @notice Called by Polygon SpokePool to send tokens over bridge to contract with the same address as this.
     * @param token Token to bridge.
     * @param amount Amount to bridge.
     * @param isMatic True if `token` is MATIC.
     */
    function send(
        PolygonIERC20 token,
        uint256 amount,
        bool isMatic
    ) public nonReentrant {
        token.safeTransferFrom(msg.sender, address(this), amount);

        // In the wMatic case, this unwraps. For other ERC20s, this is the burn/send action.
        token.withdraw(amount);

        // This takes the token that was withdrawn and calls withdraw on the "native" ERC20.
        if (isMatic) maticToken.withdraw{ value: amount }(amount);
    }

    /**
     * @notice Called by someone to send tokens to the destination, which should be set to the HubPool.
     * @param token Token to send to destination.
     */
    function retrieve(IERC20 token) public nonReentrant {
        token.safeTransfer(destination, token.balanceOf(address(this)));
    }

    receive() external payable {
        // Note: this should only happen on the mainnet side where ETH is sent to the contract directly by the bridge.
        if (functionCallStackOriginatesFromOutsideThisContract()) l1Weth.deposit{ value: address(this).balance }();
    }
}
