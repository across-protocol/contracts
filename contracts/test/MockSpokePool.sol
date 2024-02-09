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
    using SafeERC20Upgradeable for IERC20Upgradeable;

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

    function verifyUpdateV3DepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) public view {
        return
            _verifyUpdateV3DepositMessage(
                depositor,
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient,
                updatedMessage,
                depositorSignature
            );
    }

    function fillRelayV3Internal(
        V3RelayExecutionParams memory relayExecution,
        address relayer,
        bool isSlowFill
    ) external {
        _fillRelayV3(relayExecution, relayer, isSlowFill);
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

    // Use this function to unit test that relayer-v2 and sdk-v2 clients can handle FundsDeposited events while also
    // handling the new V3 events. This function is not explicitly tested in this repository but this contract is
    // exported and tested in relayer-v2 and sdk-v2 by clients that do contain logic to handle these deprecated
    // V2 events. After the V3 migration has taken place and there are no more FundsDeposited events queried by
    // the dataworker and relayer, this function can be deprecated and the V2 unit tests can be removed from
    // relayer-v2 and sdk-v2.
    function depositV2(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 // maxCount
    ) public payable nonReentrant unpausedDeposits {
        // // Check that deposit route is enabled.
        // require(enabledDepositRoutes[originToken][destinationChainId], "Disabled route");

        // // We limit the relay fees to prevent the user spending all their funds on fees.
        // require(SignedMath.abs(relayerFeePct) < 0.5e18, "Invalid relayer fee");
        // require(amount <= MAX_TRANSFER_SIZE, "Amount too large");

        // // Require that quoteTimestamp has a maximum age so that depositors pay an LP fee based on recent HubPool usage.
        // // It is assumed that cross-chain timestamps are normally loosely in-sync, but clock drift can occur. If the
        // // SpokePool time stalls or lags significantly, it is still possible to make deposits by setting quoteTimestamp
        // // within the configured buffer. The owner should pause deposits if this is undesirable. This will underflow if
        // // quoteTimestamp is more than depositQuoteTimeBuffer; this is safe but will throw an unintuitive error.

        // // slither-disable-next-line timestamp
        // require(getCurrentTime() - quoteTimestamp <= depositQuoteTimeBuffer, "invalid quoteTimestamp");

        // Increment count of deposits so that deposit ID for this spoke pool is unique.
        uint32 newDepositId = numberOfDeposits++;

        // // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // // transaction then the user is sending ETH. In this case, the ETH should be deposited to wrappedNativeToken.
        // if (originToken == address(wrappedNativeToken) && msg.value > 0) {
        //     require(msg.value == amount, "msg.value must match amount");
        //     wrappedNativeToken.deposit{ value: msg.value }();
        //     // Else, it is a normal ERC20. In this case pull the token from the user's wallet as per normal.
        //     // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them.
        //     // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        // } else IERC20Upgradeable(originToken).safeTransferFrom(msg.sender, address(this), amount);

        emit FundsDeposited(
            amount,
            chainId(),
            destinationChainId,
            relayerFeePct,
            newDepositId,
            quoteTimestamp,
            originToken,
            recipient,
            msg.sender,
            message
        );
    }
}
