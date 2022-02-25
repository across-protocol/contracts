//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";

interface PolygonIERC20 is IERC20 {
    function withdraw(uint256 amount) external;
}

/**
 * @notice Polygon specific SpokePool.
 */
contract Polygon_SpokePool is SpokePoolInterface, SpokePool {
    event PolygonTokensBridged(address indexed token, address indexed receiver, uint256 amount);

    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, 0x4200000000000000000000000000000000000006, timerAddress) {}

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        PolygonIERC20(relayerRefundLeaf.l2TokenAddress).withdraw(relayerRefundLeaf.amountToReturn);

        emit OptimismTokensBridged(relayerRefundLeaf.l2TokenAddress, address(this), relayerRefundLeaf.amountToReturn);
    }
}
