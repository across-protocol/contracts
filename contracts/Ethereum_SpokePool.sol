//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

/**
 * @notice Ethereum L1 specific SpokePool.
 * @dev Used on Ethereum L1 to facilitate L2->L1 transfers.
 */

contract Ethereum_SpokePool is SpokePoolInterface, SpokePool, Ownable {
    constructor(
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) SpokePool(msg.sender, _hubPool, _wethAddress, timerAddress) {}

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        IERC20(relayerRefundLeaf.l2TokenAddress).transfer(hubPool, relayerRefundLeaf.amountToReturn);
    }

    function _requireAdminSender() internal override onlyOwner {}
}
