//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../SpokePool.sol";
import "./interfaces/MockV2SpokePoolInterface.sol";
import "./V2MerkleLib.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../libraries/AddressConverters.sol";

/**
 * @title MockSpokePool
 * @notice Implements abstract contract for testing.
 */
contract MockSpokePool is SpokePool, MockV2SpokePoolInterface, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    uint256 private chainId_;
    uint256 private currentTime;
    mapping(bytes32 => uint256) private relayFills;

    uint256 public constant SLOW_FILL_MAX_TOKENS_TO_SEND = 1e40;

    bytes32 public constant UPDATE_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint256 depositId,uint256 originChainId,int64 updatedRelayerFeePct,address updatedRecipient,bytes updatedMessage)"
        );

    event BridgedToHubPool(uint256 amount, address token);
    event PreLeafExecuteHook(bytes32 token);

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
        uint256 depositId,
        uint256 originChainId,
        int64 updatedRelayerFeePct,
        bytes32 updatedRecipient,
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

    function verifyUpdateV3DepositMessageBytes32(
        bytes32 depositor,
        uint256 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) public view {
        return
            _verifyUpdateV3DepositMessage(
                depositor.toAddress(),
                depositId,
                originChainId,
                updatedOutputAmount,
                updatedRecipient,
                updatedMessage,
                depositorSignature,
                UPDATE_BYTES32_DEPOSIT_DETAILS_HASH
            );
    }

    function verifyUpdateV3DepositMessage(
        address depositor,
        uint256 depositId,
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
                updatedRecipient.toBytes32(),
                updatedMessage,
                depositorSignature,
                UPDATE_ADDRESS_DEPOSIT_DETAILS_HASH
            );
    }

    function fillRelayV3Internal(
        V3RelayExecutionParams memory relayExecution,
        bytes32 relayer,
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
        emit PreLeafExecuteHook(token.toBytes32());
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

        if (msg.sender.toBytes32() == relayExecution.updatedRecipient && !relayExecution.slowFill) {
            return fillAmountPreFees;
        }

        if (relayData.destinationToken == address(wrappedNativeToken).toBytes32()) {
            if (!relayExecution.slowFill) {
                IERC20Upgradeable(relayData.destinationToken.toAddress()).safeTransferFrom(
                    msg.sender,
                    address(this),
                    amountToSend
                );
            }
            _unwrapwrappedNativeTokenTo(payable(relayExecution.updatedRecipient.toAddress()), amountToSend);
        } else {
            if (!relayExecution.slowFill) {
                IERC20Upgradeable(relayData.destinationToken.toAddress()).safeTransferFrom(
                    msg.sender,
                    relayExecution.updatedRecipient.toAddress(),
                    amountToSend
                );
            } else {
                IERC20Upgradeable(relayData.destinationToken.toAddress()).safeTransfer(
                    relayExecution.updatedRecipient.toAddress(),
                    amountToSend
                );
            }
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
}
