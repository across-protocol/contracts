// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../mintburn/sponsored-oft/Structs.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @notice Minimal interface for calling deposit on SponsoredOFTSrcPeriphery
 */
interface ISponsoredOFTSrcPeriphery {
    function deposit(Quote calldata quote, bytes calldata signature) external payable;
}

/**
 * @notice Route parameters for OFT deposits
 */
struct OFTImmutables {
    uint32 dstEid;
    bytes32 destinationHandler;
    bytes32 token;
    uint256 maxOftFeeBps;
    uint256 executionFee;
    uint256 lzReceiveGasLimit;
    uint256 lzComposeGasLimit;
    uint256 maxBpsToSponsor;
    uint256 maxUserSlippageBps;
    bytes32 finalRecipient;
    bytes32 finalToken;
    uint32 destinationDex;
    uint8 accountCreationMode;
    uint8 executionMode;
    address refundRecipient;
    bytes32 userWithdrawAddress;
    bytes32 adminWithdrawAddress;
    bytes actionData;
}

/**
 * @title CounterfactualDepositOFT
 * @notice Implementation contract for counterfactual deposits via SponsoredOFT, deployed as EIP-1167 clones
 * @dev The factory deploys minimal proxies (clones) of this contract. On execution, the clone builds a
 *      Quote from its immutable route params + caller-supplied execution params and forwards it to
 *      SponsoredOFTSrcPeriphery. msg.value covers LayerZero native messaging fees.
 */
contract CounterfactualDepositOFT is ICounterfactualDeposit {
    using SafeERC20 for IERC20;

    /// @notice SponsoredOFTSrcPeriphery contract
    address public immutable oftSrcPeriphery;

    /// @notice OFT source endpoint ID for this chain
    uint32 public immutable srcEid;

    constructor(address _oftSrcPeriphery, uint32 _srcEid) {
        oftSrcPeriphery = _oftSrcPeriphery;
        srcEid = _srcEid;
    }

    /**
     * @notice Executes a deposit via SponsoredOFT
     * @param params Route parameters (verified against stored hash)
     * @param amount Gross amount of token (includes executionFee)
     * @param executionFeeRecipient Address that receives the execution fee
     * @param nonce Unique nonce for SponsoredOFT replay protection
     * @param oftDeadline Deadline for the SponsoredOFT quote (validated by SrcPeriphery)
     * @param signature Signature from SponsoredOFT quote signer
     */
    function executeDeposit(
        OFTImmutables memory params,
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes calldata signature
    ) external payable {
        _verifyParams(params);

        address tokenAddr = address(uint160(uint256(params.token)));
        if (IERC20(tokenAddr).balanceOf(address(this)) < amount) revert InsufficientBalance();

        uint256 depositAmount = amount - params.executionFee;
        if (params.executionFee > 0) {
            IERC20(tokenAddr).safeTransfer(executionFeeRecipient, params.executionFee);
        }

        IERC20(tokenAddr).safeIncreaseAllowance(oftSrcPeriphery, depositAmount);

        Quote memory quote = Quote({
            signedParams: SignedQuoteParams({
                srcEid: srcEid,
                dstEid: params.dstEid,
                destinationHandler: params.destinationHandler,
                amountLD: depositAmount,
                nonce: nonce,
                deadline: oftDeadline,
                maxBpsToSponsor: params.maxBpsToSponsor,
                maxUserSlippageBps: params.maxUserSlippageBps,
                finalRecipient: params.finalRecipient,
                finalToken: params.finalToken,
                destinationDex: params.destinationDex,
                lzReceiveGasLimit: params.lzReceiveGasLimit,
                lzComposeGasLimit: params.lzComposeGasLimit,
                maxOftFeeBps: params.maxOftFeeBps,
                accountCreationMode: params.accountCreationMode,
                executionMode: params.executionMode,
                actionData: params.actionData
            }),
            unsignedParams: UnsignedQuoteParams({ refundRecipient: params.refundRecipient })
        });

        ISponsoredOFTSrcPeriphery(oftSrcPeriphery).deposit{ value: msg.value }(quote, signature);

        emit DepositExecuted(address(this), depositAmount, nonce);
    }

    function adminWithdraw(OFTImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.adminWithdrawAddress)))) revert Unauthorized();
        IERC20(token).safeTransfer(to, amount);
        emit AdminWithdraw(address(this), token, to, amount);
    }

    function userWithdraw(OFTImmutables memory params, address token, address to, uint256 amount) external {
        _verifyParams(params);
        if (msg.sender != address(uint160(uint256(params.userWithdrawAddress)))) revert Unauthorized();
        IERC20(token).safeTransfer(to, amount);
        emit UserWithdraw(address(this), token, to, amount);
    }

    function _verifyParams(OFTImmutables memory params) internal view {
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (keccak256(abi.encode(params)) != storedHash) revert InvalidParamsHash();
    }
}
