// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";

import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice This adapter is built for emergencies to rescue funds from a Hub in the event of a misconfiguration or
 * security issue.
 */
// solhint-disable-next-line contract-name-camelcase
contract Ethereum_RescueAdapter is AdapterInterface {
    using SafeERC20 for IERC20;

    address public immutable rescueAddress;

    /**
     * @notice Constructs new Adapter.
     * @param _rescueAddress Rescue address to send funds to.
     */
    constructor(address _rescueAddress) {
        rescueAddress = _rescueAddress;
    }

    /**
     * @notice Rescues the tokens from the calling contract.
     * @param message The encoded address of the ERC20 to send to the rescue addres.
     */
    function relayMessage(address, bytes memory message) external payable override {
        IERC20 tokenAddress = IERC20(abi.decode(message, (address)));

        // Transfer full balance of tokens to the rescue address.
        tokenAddress.safeTransfer(rescueAddress, tokenAddress.balanceOf(address(this)));
    }

    /**
     * @notice Should never be called.
     */
    function relayTokens(
        address,
        address,
        uint256,
        address
    ) external payable override {
        revert("relayTokens disabled");
    }
}
