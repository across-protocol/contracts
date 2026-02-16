// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { CounterfactualDepositBase } from "./CounterfactualDepositBase.sol";

/**
 * @notice Route parameters for SpokePool deposits
 */
struct SpokePoolImmutables {
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes32 exclusiveRelayer;
    uint256 price;
    uint256 maxFeeBps;
    uint256 executionFee;
    uint32 exclusivityPeriod;
    bytes32 userWithdrawAddress;
    bytes32 adminWithdrawAddress;
    bytes message;
}

/**
 * @title CounterfactualDepositSpokePool
 * @notice Implementation contract for counterfactual deposits via Across SpokePool, deployed as EIP-1167 clones
 * @dev Unlike CCTP/OFT executors, this executor verifies EIP-712 signatures itself since it calls
 *      SpokePool.deposit() directly. The domain separator uses `address(this)` (the clone address)
 *      to prevent cross-clone replay attacks. No nonce is needed: token balance is consumed on
 *      execution (natural replay protection), and short deadlines bound the replay window.
 */
contract CounterfactualDepositSpokePool is CounterfactualDepositBase {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256("ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,uint32 fillDeadline)");

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 private constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 private constant VERSION_HASH = keccak256("1");

    /// @notice Across SpokePool contract
    address public immutable spokePool;

    /// @notice Signer that authorizes execution parameters
    address public immutable signer;

    constructor(address _spokePool, address _signer) {
        spokePool = _spokePool;
        signer = _signer;
    }

    /**
     * @notice Executes a deposit via Across SpokePool
     * @param params Route parameters (verified against stored hash)
     * @param inputAmount Gross amount of inputToken (includes executionFee)
     * @param outputAmount Output amount signed by signer, passed to SpokePool
     * @param executionFeeRecipient Address that receives the execution fee
     * @param quoteTimestamp Quote timestamp from Across API (SpokePool validates recency)
     * @param fillDeadline Timestamp by which the deposit must be filled
     * @param signature EIP-712 signature from signer over (inputAmount, outputAmount, fillDeadline)
     */
    function executeDeposit(
        SpokePoolImmutables memory params,
        uint256 inputAmount,
        uint256 outputAmount,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        bytes calldata signature
    ) external {
        _verifySignature(inputAmount, outputAmount, fillDeadline, signature);
        _verifyParams(params);

        address inputTokenAddr = address(uint160(uint256(params.inputToken)));
        if (IERC20(inputTokenAddr).balanceOf(address(this)) < inputAmount) revert InsufficientBalance();

        // amount to deposit into SpokePool
        uint256 depositAmount = inputAmount - params.executionFee;

        // Fee check: convert outputAmount to inputToken units, compute total fee in bps
        uint256 outputInInputToken = (outputAmount * params.price) / PRECISION_SCALAR;
        uint256 relayerFee = depositAmount > outputInInputToken ? depositAmount - outputInInputToken : 0;
        uint256 totalFee = relayerFee + params.executionFee;
        if (totalFee * BPS_SCALAR > params.maxFeeBps * inputAmount) revert MaxFee();

        uint32 exclusivityDeadline = params.exclusivityPeriod > 0
            ? uint32(block.timestamp) + params.exclusivityPeriod
            : 0;

        IERC20(inputTokenAddr).forceApprove(spokePool, depositAmount);

        V3SpokePoolInterface(spokePool).deposit(
            params.userWithdrawAddress, // depositor — SpokePool refunds go to user, not clone
            params.recipient,
            params.inputToken,
            params.outputToken,
            depositAmount,
            outputAmount,
            params.destinationChainId,
            params.exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            params.message
        );

        if (params.executionFee > 0) {
            IERC20(inputTokenAddr).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        emit DepositExecuted(address(this), depositAmount, bytes32(0));
    }

    function adminWithdraw(SpokePoolImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _adminWithdraw(params.adminWithdrawAddress, token, to, amount);
    }

    function userWithdraw(SpokePoolImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        _userWithdraw(params.userWithdrawAddress, token, to, amount);
    }

    function _verifySignature(
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 fillDeadline,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(abi.encode(EXECUTE_DEPOSIT_TYPEHASH, inputAmount, outputAmount, fillDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();
    }

    function _verifyParams(SpokePoolImmutables memory params) internal view {
        _verifyParamsHash(keccak256(abi.encode(params)));
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }
}
