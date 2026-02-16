// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { V3SpokePoolInterface } from "../../interfaces/V3SpokePoolInterface.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @notice Route parameters for SpokePool deposits
 */
struct SpokePoolImmutables {
    uint256 destinationChainId;
    bytes32 inputToken;
    bytes32 outputToken;
    bytes32 recipient;
    bytes32 exclusiveRelayer;
    uint256 exchangeRate;
    uint256 maxRelayerFee;
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
contract CounterfactualDepositSpokePool is ICounterfactualDeposit {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256("ExecuteDeposit(uint256 amount,uint256 outputAmount,uint32 fillDeadline)");

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
     * @param amount Gross amount of inputToken (includes executionFee)
     * @param outputAmount Output amount signed by signer, passed to SpokePool
     * @param executionFeeRecipient Address that receives the execution fee
     * @param quoteTimestamp Quote timestamp from Across API (SpokePool validates recency)
     * @param fillDeadline Timestamp by which the deposit must be filled
     * @param signature EIP-712 signature from signer over (amount, outputAmount, fillDeadline)
     */
    function executeDeposit(
        SpokePoolImmutables memory params,
        uint256 amount,
        uint256 outputAmount,
        address executionFeeRecipient,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        bytes calldata signature
    ) external {
        bytes32 structHash = keccak256(abi.encode(EXECUTE_DEPOSIT_TYPEHASH, amount, outputAmount, fillDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        if (ECDSA.recover(digest, signature) != signer) revert InvalidSignature();

        _verifyParams(params);

        address inputTokenAddr = address(uint160(uint256(params.inputToken)));
        if (IERC20(inputTokenAddr).balanceOf(address(this)) < amount) revert InsufficientBalance();

        uint256 depositAmount = amount - params.executionFee;
        if (params.executionFee > 0) {
            IERC20(inputTokenAddr).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        // Relayer fee check: ensure relayer fee doesn't exceed maxRelayerFee
        uint256 expectedOutput = (depositAmount * params.exchangeRate) / 1e18;
        if (expectedOutput > outputAmount && expectedOutput - outputAmount > params.maxRelayerFee) {
            revert ExcessiveRelayerFee();
        }

        uint32 exclusivityDeadline = params.exclusivityPeriod > 0
            ? uint32(block.timestamp) + params.exclusivityPeriod
            : 0;

        IERC20(inputTokenAddr).safeIncreaseAllowance(spokePool, depositAmount);

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

        emit DepositExecuted(address(this), depositAmount, bytes32(0));
    }

    function adminWithdraw(SpokePoolImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.adminWithdrawAddress)))) revert Unauthorized();
        IERC20(token).safeTransfer(to, amount);
        emit AdminWithdraw(address(this), token, to, amount);
    }

    function userWithdraw(SpokePoolImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.userWithdrawAddress)))) revert Unauthorized();
        IERC20(token).safeTransfer(to, amount);
        emit UserWithdraw(address(this), token, to, amount);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
    }

    function _verifyParams(SpokePoolImmutables memory params) internal view {
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (keccak256(abi.encode(params)) != storedHash) revert InvalidParamsHash();
    }
}
