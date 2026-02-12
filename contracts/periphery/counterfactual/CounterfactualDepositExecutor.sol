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

    /// @notice Factory contract (immutable, same for all deposits on this chain)
    address public immutable factory;

    /// @notice SponsoredCCTPSrcPeriphery contract (immutable, same for all deposits on this chain)
    address public immutable srcPeriphery;

    /// @notice CCTP source domain ID for this chain
    uint32 public immutable sourceDomain;

    /**
     * @notice Constructs the executor with chain-specific constants
     * @param _factory Factory contract address
     * @param _srcPeriphery SponsoredCCTPSrcPeriphery contract address
     * @param _sourceDomain CCTP source domain ID for this chain
     */
    constructor(address _factory, address _srcPeriphery, uint32 _sourceDomain) {
        factory = _factory;
        srcPeriphery = _srcPeriphery;
        sourceDomain = _sourceDomain;
    }

    /**
     * @notice Executes a deposit via SponsoredCCTP
     * @dev Called on EIP-1167 clone instances; reads route params from clone immutable args,
     *      builds a SponsoredCCTPQuote, and calls SponsoredCCTPSrcPeriphery.depositForBurn.
     *      Signature verification, nonce tracking, and deadline checks are all handled by SrcPeriphery.
     * @param amount Amount of burnToken to deposit
     * @param nonce Unique nonce for replay protection (enforced by SrcPeriphery)
     * @param deadline Quote expiration timestamp (enforced by SrcPeriphery)
     * @param signature Signature from SponsoredCCTP quote signer (verified by SrcPeriphery)
     */
    function executeDeposit(uint256 amount, bytes32 nonce, uint256 deadline, bytes calldata signature) external {
        ICounterfactualDepositFactory.CCTPRouteParams memory params = _getRouteParams();

        address burnTokenAddr = address(uint160(uint256(params.burnToken)));
        uint256 balance = IERC20(burnTokenAddr).balanceOf(address(this));
        if (balance < amount) revert ICounterfactualDepositFactory.InsufficientBalance();

        // Compute maxFee from maxFeeBps and deposit amount
        uint256 maxFee = (amount * params.maxFeeBps) / 10000;

        // Build the SponsoredCCTPQuote from clone immutable args + execution params
        SponsoredCCTPInterface.SponsoredCCTPQuote memory quote = SponsoredCCTPInterface.SponsoredCCTPQuote({
            sourceDomain: sourceDomain,
            destinationDomain: params.destinationDomain,
            mintRecipient: params.mintRecipient,
            amount: amount,
            burnToken: params.burnToken,
            destinationCaller: params.destinationCaller,
            maxFee: maxFee,
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
        });

        // Approve SrcPeriphery to pull tokens (it calls safeTransferFrom)
        IERC20(burnTokenAddr).safeIncreaseAllowance(srcPeriphery, amount);

        // Execute deposit — SrcPeriphery validates signature, nonce, deadline, and sourceDomain
        ISponsoredCCTPSrcPeriphery(srcPeriphery).depositForBurn(quote, signature);

        emit ICounterfactualDepositFactory.DepositExecuted(address(this), amount, nonce);
    }

    /**
     * @notice Allows admin to withdraw tokens from the deposit contract
     * @dev Used for recovering wrongly sent tokens
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function adminWithdraw(address token, address to, uint256 amount) external {
        if (msg.sender != ICounterfactualDepositFactory(factory).admin()) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Allows the refundAddress to withdraw tokens from the deposit contract
     * @dev Escape hatch for users who change their mind before execution
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function userWithdraw(address token, address to, uint256 amount) external {
        ICounterfactualDepositFactory.CCTPRouteParams memory params = _getRouteParams();
        if (msg.sender != address(uint160(uint256(params.refundAddress)))) {
            revert ICounterfactualDepositFactory.Unauthorized();
        }
        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @notice Gets route parameters from clone immutable args appended to bytecode
     * @dev Uses OZ Clones.fetchCloneArgs to read args set during cloneDeterministicWithImmutableArgs
     */
    function _getRouteParams() internal view returns (ICounterfactualDepositFactory.CCTPRouteParams memory) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        return abi.decode(args, (ICounterfactualDepositFactory.CCTPRouteParams));
    }
}
