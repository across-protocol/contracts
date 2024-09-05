// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./interfaces/AdapterInterface.sol";
import { USDYieldManager } from "../Blast_DaiRetriever.sol";

import "@openzeppelin/contracts5/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts5/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice This adapter is built to to retrieve Blast USDB from the USDBYieldManager contract on Ethereum that was
 * sent to the HubPool as the `recipient`. These funds should ideally be sent to the BlastRetriever address on
 * Ethereum. This contract can be used to retrieve these funds.
 */
// solhint-disable-next-line contract-name-camelcase
contract Blast_RescueAdapter is AdapterInterface {
    using SafeERC20 for IERC20;

    address public immutable rescueAddress;

    USDYieldManager public immutable usdYieldManager;

    /**
     * @notice Constructs new Adapter.
     * @param _rescueAddress Rescue address to send funds to.
     */
    constructor(address _rescueAddress, USDYieldManager _usdYieldManager) {
        rescueAddress = _rescueAddress;
        usdYieldManager = _usdYieldManager;
    }

    /**
     * @notice Rescues the tokens from the calling contract.
     * @param message The encoded address of the ERC20 to send to the rescue addres.
     */
    function relayMessage(address, bytes memory message) external payable override {
        (uint256 requestId, uint256 hintId) = abi.decode(message, (uint256, uint256));
        require(usdYieldManager.claimWithdrawal(requestId, hintId), "claim failed");
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
