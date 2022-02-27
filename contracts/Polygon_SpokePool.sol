//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "./interfaces/WETH9.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SpokePool.sol";
import "./SpokePoolInterface.sol";
import "./PolygonTokenBridger.sol";

// ERC20s (on polygon) compatible with polygon's bridge have a withdraw method.
interface PolygonIERC20 is IERC20 {
    function withdraw(uint256 amount) external;
}

// IFxMessageProcessor represents interface to process messages.
interface IFxMessageProcessor {
    function processMessageFromRoot(
        uint256 stateId,
        address rootMessageSender,
        bytes calldata data
    ) external;
}

/**
 * @notice Polygon specific SpokePool.
 */
contract Polygon_SpokePool is SpokePoolInterface, IFxMessageProcessor, SpokePool {
    using SafeERC20 for PolygonIERC20;
    address public fxChild;
    PolygonTokenBridger public polygonTokenBridger;
    bool private callValidated = false;

    event PolygonTokensBridged(address indexed token, address indexed receiver, uint256 amount);

    constructor(
        PolygonTokenBridger _polygonTokenBridger,
        address _crossDomainAdmin,
        address _hubPool,
        address _wmaticAddress, // Note: wmatic is used here since it is the token sent via msg.value on polygon.
        address timerAddress
    ) SpokePool(_crossDomainAdmin, _hubPool, _wmaticAddress, timerAddress) {
        polygonTokenBridger = _polygonTokenBridger;
    }

    function processMessageFromRoot(
        uint256,
        address rootMessageSender,
        bytes calldata data
    ) public {
        // Validation logic.
        require(msg.sender == fxChild, "Not from fxChild");
        require(rootMessageSender == hubPool, "Not from mainnet HubPool");

        // This sets a variable indicating that we're now inside a validated call.
        // Note: this is used by other methods to ensure that this call has been validated by this method and is not
        // spoofed.
        callValidated = true;

        // This uses delegatecall to take the information in the message and process it as a function call on this contract.
        (bool success, ) = address(this).delegatecall(data);
        require(success, "delegatecall failed");

        // Reset callValidated to false to disallow admin calls after this method exits.
        callValidated = false;
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    function _bridgeTokensToHubPool(RelayerRefundLeaf memory relayerRefundLeaf) internal override {
        PolygonIERC20(relayerRefundLeaf.l2TokenAddress).safeIncreaseAllowance(relayerRefundLeaf.amountToReturn);
        polygonTokenBridger.send(relayerRefundLeaf.l2TokenAddress, relayerRefundLeaf.amountToReturn);

        emit PolygonTokensBridged(relayerRefundLeaf.l2TokenAddress, address(this), relayerRefundLeaf.amountToReturn);
    }

    function _requireAdminSender() internal view override {
        require(callValidated, "Must call processMessageFromRoot");
    }
}
