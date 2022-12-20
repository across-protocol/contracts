// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";
import "../SpokePoolInterface.sol";
import "../SpokePool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Used on Ethereum to send tokens from SpokePool to HubPool
 */
contract Ethereum_SpokeAdapter is SpokeAdapterInterface {
    using SafeERC20 for IERC20;

    address public immutable spokePool;

    constructor(address _spokePool) {
        spokePool = _spokePool;
    }

    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        IERC20(l2TokenAddress).safeTransfer(SpokePoolInterface(spokePool).hubPool(), amountToReturn);
    }
}
