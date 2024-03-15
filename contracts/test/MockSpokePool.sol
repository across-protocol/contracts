//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../SpokePool.sol";
import "./interfaces/MockV2SpokePoolInterface.sol";
import "./V2MerkleLib.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePool, MockV2SpokePoolInterface, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    uint256 private chainId_;
    uint256 private currentTime;
    mapping(bytes32 => uint256) private relayFills;

    uint256 public constant SLOW_FILL_MAX_TOKENS_TO_SEND = 1e40;

    bytes32 public constant UPDATE_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,int64 updatedRelayerFeePct,address updatedRecipient,bytes updatedMessage)"
        );

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

    function _verifyUpdateDepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        int64 updatedRelayerFeePct,
        address updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) internal view {
        bytes32 expectedTypedDataV4Hash = _hashTypedDataV4(
            // EIP-712 compliant hash struct: https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct
            keccak256(
                abi.encode(
                    UPDATE_DEPOSIT_DETAILS_HASH,
                    depositId,
                    originChainId,
                    updatedRelayerFeePct,
                    updatedRecipient,
                    keccak256(updatedMessage)
                )
            ),
            // By passing in the origin chain id, we enable the verification of the signature on a different chain
            originChainId
        );
        _verifyDepositorSignature(depositor, expectedTypedDataV4Hash, depositorSignature);
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

    function depositV2(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 // maxCount
    ) public payable virtual nonReentrant unpausedDeposits {
        // Increment count of deposits so that deposit ID for this spoke pool is unique.
        uint32 newDepositId = numberOfDeposits++;

        if (originToken == address(wrappedNativeToken) && msg.value > 0) {
            require(msg.value == amount);
            wrappedNativeToken.deposit{ value: msg.value }();
        } else IERC20Upgradeable(originToken).safeTransferFrom(msg.sender, address(this), amount);

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

    function fillRelay(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        bytes memory message,
        uint256 maxCount
    ) public nonReentrant unpausedFills {
        RelayExecution memory relayExecution = RelayExecution({
            relay: MockV2SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: chainId(),
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: relayerFeePct,
            updatedRecipient: recipient,
            updatedMessage: message,
            repaymentChainId: repaymentChainId,
            maxTokensToSend: maxTokensToSend,
            slowFill: false,
            payoutAdjustmentPct: 0,
            maxCount: maxCount
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        uint256 fillAmountPreFees = _fillRelay(relayExecution);
        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    function executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes memory message,
        int256 payoutAdjustment,
        bytes32[] memory proof
    ) public nonReentrant {
        _executeSlowRelayLeaf(
            depositor,
            recipient,
            destinationToken,
            amount,
            originChainId,
            chainId(),
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            message,
            payoutAdjustment,
            proof
        );
    }

    function fillRelayWithUpdatedDeposit(
        address depositor,
        address recipient,
        address updatedRecipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        int64 updatedRelayerFeePct,
        uint32 depositId,
        bytes memory message,
        bytes memory updatedMessage,
        bytes memory depositorSignature,
        uint256 maxCount
    ) public nonReentrant unpausedFills {
        RelayExecution memory relayExecution = RelayExecution({
            relay: MockV2SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: chainId(),
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: updatedRelayerFeePct,
            updatedRecipient: updatedRecipient,
            updatedMessage: updatedMessage,
            repaymentChainId: repaymentChainId,
            maxTokensToSend: maxTokensToSend,
            slowFill: false,
            payoutAdjustmentPct: 0,
            maxCount: maxCount
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        _verifyUpdateDepositMessage(
            depositor,
            depositId,
            originChainId,
            updatedRelayerFeePct,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );
        uint256 fillAmountPreFees = _fillRelay(relayExecution);
        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    function _executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes memory message,
        int256 payoutAdjustmentPct,
        bytes32[] memory proof
    ) internal {
        RelayExecution memory relayExecution = RelayExecution({
            relay: MockV2SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: destinationChainId,
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: 0,
            updatedRecipient: recipient,
            updatedMessage: message,
            repaymentChainId: 0,
            maxTokensToSend: SLOW_FILL_MAX_TOKENS_TO_SEND,
            slowFill: true,
            payoutAdjustmentPct: payoutAdjustmentPct,
            maxCount: type(uint256).max
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        _verifySlowFill(relayExecution, rootBundleId, proof);

        uint256 fillAmountPreFees = _fillRelay(relayExecution);

        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    function _computeAmountPreFees(uint256 amount, int64 feesPct) private pure returns (uint256) {
        return (1e18 * amount) / uint256((int256(1e18) - feesPct));
    }

    function __computeAmountPostFees(uint256 amount, int256 feesPct) private pure returns (uint256) {
        return (amount * uint256(int256(1e18) - feesPct)) / 1e18;
    }

    function _getRelayHash(MockV2SpokePoolInterface.RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(relayData));
    }

    function _fillRelay(RelayExecution memory relayExecution) internal returns (uint256 fillAmountPreFees) {
        MockV2SpokePoolInterface.RelayData memory relayData = relayExecution.relay;

        require(relayFills[relayExecution.relayHash] < relayData.amount, "relay filled");

        fillAmountPreFees = _computeAmountPreFees(
            relayExecution.maxTokensToSend,
            (relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct)
        );
        require(fillAmountPreFees > 0, "fill amount pre fees is 0");

        uint256 amountRemainingInRelay = relayData.amount - relayFills[relayExecution.relayHash];
        if (amountRemainingInRelay < fillAmountPreFees) {
            fillAmountPreFees = amountRemainingInRelay;
        }

        uint256 amountToSend = __computeAmountPostFees(
            fillAmountPreFees,
            relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct
        );

        if (relayExecution.payoutAdjustmentPct != 0) {
            require(relayExecution.payoutAdjustmentPct >= -1e18, "payoutAdjustmentPct too small");
            require(relayExecution.payoutAdjustmentPct <= 100e18, "payoutAdjustmentPct too large");

            amountToSend = __computeAmountPostFees(amountToSend, -relayExecution.payoutAdjustmentPct);
            require(amountToSend <= relayExecution.maxTokensToSend, "Somehow hit maxTokensToSend!");
        }

        bool localRepayment = relayExecution.repaymentChainId == relayExecution.relay.destinationChainId;
        require(
            localRepayment || relayExecution.relay.amount == fillAmountPreFees || relayExecution.slowFill,
            "invalid repayment chain"
        );

        relayFills[relayExecution.relayHash] += fillAmountPreFees;

        if (msg.sender == relayExecution.updatedRecipient && !relayExecution.slowFill) return fillAmountPreFees;

        if (relayData.destinationToken == address(wrappedNativeToken)) {
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapwrappedNativeTokenTo(payable(relayExecution.updatedRecipient), amountToSend);
        } else {
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(
                    msg.sender,
                    relayExecution.updatedRecipient,
                    amountToSend
                );
            else
                IERC20Upgradeable(relayData.destinationToken).safeTransfer(
                    relayExecution.updatedRecipient,
                    amountToSend
                );
        }
    }

    function _verifySlowFill(
        RelayExecution memory relayExecution,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) internal view {
        SlowFill memory slowFill = SlowFill({
            relayData: relayExecution.relay,
            payoutAdjustmentPct: relayExecution.payoutAdjustmentPct
        });

        require(
            V2MerkleLib.verifySlowRelayFulfillment(rootBundles[rootBundleId].slowRelayRoot, slowFill, proof),
            "Invalid slow relay proof"
        );
    }

    function _emitFillRelay(RelayExecution memory relayExecution, uint256 fillAmountPreFees) internal {
        RelayExecutionInfo memory relayExecutionInfo = RelayExecutionInfo({
            relayerFeePct: relayExecution.updatedRelayerFeePct,
            recipient: relayExecution.updatedRecipient,
            message: relayExecution.updatedMessage,
            isSlowRelay: relayExecution.slowFill,
            payoutAdjustmentPct: relayExecution.payoutAdjustmentPct
        });

        emit FilledRelay(
            relayExecution.relay.amount,
            relayFills[relayExecution.relayHash],
            fillAmountPreFees,
            relayExecution.repaymentChainId,
            relayExecution.relay.originChainId,
            relayExecution.relay.destinationChainId,
            relayExecution.relay.relayerFeePct,
            relayExecution.relay.realizedLpFeePct,
            relayExecution.relay.depositId,
            relayExecution.relay.destinationToken,
            msg.sender,
            relayExecution.relay.depositor,
            relayExecution.relay.recipient,
            relayExecution.relay.message,
            relayExecutionInfo
        );
    }
}
