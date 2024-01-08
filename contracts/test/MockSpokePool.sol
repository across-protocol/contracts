//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../SpokePool.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePool, OwnableUpgradeable {
    uint256 private chainId_;
    uint256 private currentTime;

    event BridgedToHubPool(uint256 amount, address token);
    event PreLeafExecuteHook(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _wrappedNativeTokenAddress) SpokePool(_wrappedNativeTokenAddress, 1 hours, 9 hours) {} // solhint-disable-line no-empty-blocks

    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __Ownable_init();
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        currentTime = block.timestamp; // solhint-disable-line not-rely-on-time
    }

    function setCurrentTime(uint256 time) external {
        currentTime = time;
    }

    function distributeRelayerRefunds(
        uint256 _chainId,
        uint256 amountToReturn,
        uint256[] memory refundAmounts,
        uint32 leafId,
        address l2TokenAddress,
        address[] memory refundAddresses
    ) external {
        _distributeRelayerRefunds(_chainId, amountToReturn, refundAmounts, leafId, l2TokenAddress, refundAddresses);
    }

    function verifyUpdateUSSDepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) public view {
        return
            _verifyUpdateUSSDepositMessage(
                depositor,
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient,
                updatedMessage,
                depositorSignature
            );
    }

    function fillRelayUSSInternal(
        USSRelayExecutionParams memory relayExecution,
        address relayer,
        bool isSlowFill
    ) external {
        _fillRelayUSS(relayExecution, relayer, isSlowFill);
    }

    // This function is nonReentrant in order to allow caller to test whether a different function
    // is reentrancy protected or not.
    function callback(bytes memory data) external payable nonReentrant {
        (bool success, bytes memory result) = address(this).call{ value: msg.value }(data);
        require(success, string(result));
    }

    function setFillStatus(bytes32 relayHash, FillType fillType) external {
        fillStatuses[relayHash] = uint256(fillType);
    }

    function getCurrentTime() public view override returns (uint256) {
        return currentTime;
    }

    function _preExecuteLeafHook(address token) internal override {
        emit PreLeafExecuteHook(token);
    }

    function _bridgeTokensToHubPool(uint256 amount, address token) internal override {
        emit BridgedToHubPool(amount, token);
    }

    function _requireAdminSender() internal override onlyOwner {} // solhint-disable-line no-empty-blocks

    function chainId() public view override(SpokePool) returns (uint256) {
        // If chainId_ is set then return it, else do nothing and return the parent chainId().
        return chainId_ == 0 ? super.chainId() : chainId_;
    }

    function setChainId(uint256 _chainId) public {
        chainId_ = _chainId;
    }
}
