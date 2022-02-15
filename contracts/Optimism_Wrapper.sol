// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Optimism Eth Wrapper
 * @dev Any ETH sent to this contract is wrapped into WETH and sent to the set hubPool. This enables ETH to be sent
 * over the canonical Optimism bridge, which does not support WETH bridging.
 */
interface WETH9Like {
    function deposit() external payable;

    function transfer(address guy, uint256 wad) external;

    function balanceOf(address guy) external view returns (uint256);
}

contract Optimism_Wrapper is Ownable {
    WETH9Like public weth;
    address public hubPool;

    event ChangedhubPool(address indexed hubPool);

    /**
     * @notice Construct Optimism Wrapper contract.
     * @param _weth l1WethContract address. Normally deployed at 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2.
     * @param _hubPool address of the hubPool to send Wrapped ETH to when ETH is sent to this contract.
     */
    constructor(WETH9Like _weth, address _hubPool) {
        weth = _weth;
        hubPool = _hubPool;
        emit ChangedhubPool(hubPool);
    }

    /**
     * @notice Called by owner of the wrapper to change the destination of the wrapped ETH (hubPool).
     * @param newhubPool address of the hubPool to send Wrapped ETH to when ETH is sent to this contract.
     */
    function changehubPool(address newhubPool) public onlyOwner {
        hubPool = newhubPool;
        emit ChangedhubPool(hubPool);
    }

    /**
     * @notice Publicly callable function that takes all ETH in this contract, wraps it to WETH and sends it to the
     * hubPool contract. Function is called by fallback functions to automatically wrap ETH to WETH and send at the
     * conclusion of a canonical ETH bridging action.
     */
    function wrapAndTransfer() public payable {
        weth.deposit{ value: address(this).balance }();
        weth.transfer(hubPool, weth.balanceOf(address(this)));
    }

    // Fallback function enable this contract to receive funds when they are unwrapped from the weth contract.
    fallback() external payable {
        wrapAndTransfer();
    }
}
