// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Interface for the WETH9 contract.
 */
interface WETH9Interface {
    /**
     * @notice Burn Wrapped Ether and receive native Ether.
     * @param wad Amount of WETH to unwrap and send to caller.
     */
    function withdraw(uint256 wad) external;

    /**
     * @notice Lock native Ether and mint Wrapped Ether ERC20
     * @dev msg.value is amount of Wrapped Ether to mint/Ether to lock.
     */
    function deposit() external payable;

    /**
     * @notice Get balance of WETH held by `guy`.
     * @param guy Address to get balance of.
     * @return wad Amount of WETH held by `guy`.
     */
    function balanceOf(address guy) external view returns (uint256 wad);

    /**
     * @notice Transfer `wad` of WETH from caller to `guy`.
     * @param guy Address to send WETH to.
     * @param wad Amount of WETH to send.
     * @return ok True if transfer succeeded.
     */
    function transfer(address guy, uint256 wad) external returns (bool);
}
