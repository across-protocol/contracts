// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokeAdapterInterface.sol";
import "../SpokePoolInterface.sol";
import "../PolygonTokenBridger.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice Used on Polygon to send tokens from SpokePool to HubPool
 */
contract Polygon_SpokeAdapter is SpokeAdapterInterface {
    using SafeERC20 for PolygonIERC20;

    address public immutable spokePool;

    // Contract deployed on L1 and L2 processes all cross-chain transfers between this contract and the the HubPool.
    // Required because bridging tokens from Polygon to Ethereum has special constraints.
    PolygonTokenBridger public immutable polygonTokenBridger;

    event PolygonTokensBridged(address indexed token, address indexed receiver, uint256 amount);

    constructor(address _spokePool, PolygonTokenBridger _polygonTokenBridger) {
        spokePool = _spokePool;
        polygonTokenBridger = _polygonTokenBridger;
    }

    /**************************************
     *          INTERNAL FUNCTIONS           *
     **************************************/

    function bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) external override {
        PolygonIERC20(l2TokenAddress).safeIncreaseAllowance(address(polygonTokenBridger), amountToReturn);

        // Note: WrappedNativeToken is WMATIC on matic, so this tells the tokenbridger that this is an unwrappable native token.
        polygonTokenBridger.send(PolygonIERC20(l2TokenAddress), amountToReturn);

        emit PolygonTokensBridged(l2TokenAddress, address(this), amountToReturn);
    }
}
