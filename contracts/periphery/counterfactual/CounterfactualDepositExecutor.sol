// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SponsoredCCTPInterface } from "../../interfaces/SponsoredCCTPInterface.sol";
import { ICounterfactualDepositFactory } from "../../interfaces/ICounterfactualDepositFactory.sol";

/**
 * @notice Minimal interface for calling depositForBurn on SponsoredCCTPSrcPeriphery
 */
interface ISponsoredCCTPSrcPeriphery {
    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory signature) external;
}

/**
 * @title CounterfactualDepositExecutor
 * @notice Implementation contract for counterfactual deposits via SponsoredCCTP, deployed as EIP-1167 clones
 * @dev The factory deploys minimal proxies (clones) of this contract using OZ Clones.cloneDeterministicWithImmutableArgs.
 * Route parameters are appended to the clone bytecode and read via Clones.fetchCloneArgs.
 * On execution, the clone builds a SponsoredCCTPQuote from its immutable route params + caller-supplied
 * execution params (amount, nonce, deadline) and forwards it to SponsoredCCTPSrcPeriphery.
 */
contract CounterfactualDepositExecutor {
    using SafeERC20 for IERC20;

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /**
     * @notice Constructs the executor with chain-specific constants
     * @param _srcPeriphery SponsoredCCTPSrcPeriphery contract address
     * @param _sourceDomain CCTP source domain ID for this chain
     */
    constructor(address _srcPeriphery, uint32 _sourceDomain) {
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /**
     * @notice Executes a deposit via SponsoredCCTP
     * @dev Called on EIP-1167 clone instances. The clone stores only a keccak256 hash of the route params;
     *      full params are passed by the caller and verified against the stored hash before execution.
     *      Signature verification, nonce tracking, and deadline checks are all handled by SrcPeriphery.
     * @param params Route parameters (verified against stored hash)
     * @param amount Gross amount of burnToken (includes executionFee)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param nonce Unique nonce for replay protection (enforced by SrcPeriphery)
     * @param deadline Quote expiration timestamp (enforced by SrcPeriphery)
     * @param signature Signature from SponsoredCCTP quote signer (verified by SrcPeriphery)
     */
    function executeDeposit(
        ICounterfactualDepositFactory.CounterfactualImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _verifyParams(params);

        address burnTokenAddr = address(uint160(uint256(params.burnToken)));
        if (IERC20(burnTokenAddr).balanceOf(address(this)) < amount) {
            revert ICounterfactualDepositFactory.InsufficientBalance();
        }

        // Pay execution fee to relayer, compute net deposit amount
        uint256 depositAmount = amount - params.executionFee;
        if (params.executionFee > 0) {
            IERC20(burnTokenAddr).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        // Approve SrcPeriphery to pull tokens and execute deposit
        IERC20(burnTokenAddr).safeIncreaseAllowance(srcPeriphery, depositAmount);
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(
            SponsoredCCTPInterface.SponsoredCCTPQuote({
                sourceDomain: sourceDomain,
                destinationDomain: params.destinationDomain,
                mintRecipient: params.mintRecipient,
                amount: depositAmount,
                burnToken: params.burnToken,
                destinationCaller: params.destinationCaller,
                maxFee: (depositAmount * params.cctpMaxFeeBps) / 10000,
                minFinalityThreshold: params.minFinalityThreshold,
                nonce: nonce,
                deadline: deadline,
                maxBpsToSponsor: params.maxBpsToSponsor,
                maxUserSlippageBps: params.maxUserSlippageBps,
                finalRecipient: params.finalRecipient,
                finalToken: params.finalToken,
                destinationDex: params.destinationDex,
                accountCreationMode: params.accountCreationMode,
                executionMode: params.executionMode,
                actionData: params.actionData
            }),
            signature
        );

        emit ICounterfactualDepositFactory.DepositExecuted(address(this), depositAmount, nonce);
    }

    /**
     * @notice Allows admin to withdraw tokens from the deposit contract
     * @dev Used for recovering wrongly sent tokens. Admin is stored in the clone's route params hash.
     * @param params Route parameters (verified against stored hash)
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function adminWithdraw(
        ICounterfactualDepositFactory.CounterfactualImmutables memory params,
        address token,
        address to,
        uint256 amount
    ) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.adminWithdrawAddress)))) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }
        IERC20(token).safeTransfer(to, amount);
        emit ICounterfactualDepositFactory.AdminWithdraw(address(this), token, to, amount);
    }

    /**
     * @notice Allows the userWithdrawAddress to withdraw tokens from the deposit contract
     * @dev Escape hatch for users who change their mind before execution.
     *      Caller must pass the full route params so userWithdrawAddress can be extracted after hash verification.
     * @param params Route parameters (verified against stored hash)
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function userWithdraw(
        ICounterfactualDepositFactory.CounterfactualImmutables memory params,
        address token,
        address to,
        uint256 amount
    ) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.userWithdrawAddress)))) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }
        IERC20(token).safeTransfer(to, amount);
        emit ICounterfactualDepositFactory.UserWithdraw(address(this), token, to, amount);
    }

    /**
     * @notice Verifies that provided params match the hash stored in clone immutable args
     * @dev The clone stores only a keccak256 hash (32 bytes) of the full params to minimize deployment gas.
     *      Callers must pass the full params, which are hashed and compared against the stored hash.
     * @param params Route parameters to verify
     */
    function _verifyParams(ICounterfactualDepositFactory.CounterfactualImmutables memory params) internal view {
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (keccak256(abi.encode(params)) != storedHash) {
            revert ICounterfactualDepositFactory.InvalidParamsHash();
        }
    }
}
