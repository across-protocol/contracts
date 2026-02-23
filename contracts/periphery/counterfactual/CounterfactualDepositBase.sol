// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

struct CounterfactualDepositGlobalConfig {
    bytes32 sharedParamsHash;
    bytes32 routesRoot;
    address userWithdrawAddress;
    address adminWithdrawAddress;
}

/**
 * @title CounterfactualDepositBase
 * @notice Shared logic for the unified counterfactual deposit executor.
 */
contract CounterfactualDepositBase is ICounterfactualDeposit {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_SCALAR = 10_000;
    uint256 internal constant EXCHANGE_RATE_SCALAR = 1e18;

    /// @notice Sentinel address representing native ETH in withdraw calls.
    address public constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Verifies caller-supplied params hash against the clone's stored hash.
    modifier verifyParamsHash(bytes32 paramsHash) {
        bytes32 storedHash = abi.decode(Clones.fetchCloneArgs(address(this)), (bytes32));
        if (paramsHash != storedHash) revert InvalidParamsHash();
        _;
    }

    function _verifyRoute(
        CounterfactualDepositGlobalConfig memory globalConfig,
        bytes32 routeLeaf,
        bytes32[] calldata proof
    ) internal pure {
        if (!MerkleProof.verify(proof, globalConfig.routesRoot, routeLeaf)) revert InvalidRouteProof();
    }

    /**
     * @notice Allows the admin to withdraw any token from this clone (e.g. recovery of stuck funds).
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function adminWithdraw(
        bytes calldata params,
        address token,
        address to,
        uint256 amount
    ) external verifyParamsHash(keccak256(params)) {
        if (msg.sender != _getAdminWithdrawAddress(params)) revert Unauthorized();
        _transferOut(token, to, amount);
        emit AdminWithdraw(token, to, amount);
    }

    /**
     * @notice Admin withdraw that always sends to the clone's userWithdrawAddress.
     * @dev Used by AdminWithdrawManager.signedWithdrawToUser so the recipient is enforced on-chain.
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param amount Amount to withdraw.
     */
    function adminWithdrawToUser(
        bytes calldata params,
        address token,
        uint256 amount
    ) external verifyParamsHash(keccak256(params)) {
        if (msg.sender != _getAdminWithdrawAddress(params)) revert Unauthorized();
        address to = _getUserWithdrawAddress(params);
        _transferOut(token, to, amount);
        emit AdminWithdraw(token, to, amount);
    }

    /**
     * @notice Allows the user to withdraw tokens before execution (escape hatch).
     * @param params ABI-encoded route parameters (verified against stored hash).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param to Recipient of the withdrawn tokens.
     * @param amount Amount to withdraw.
     */
    function userWithdraw(
        bytes calldata params,
        address token,
        address to,
        uint256 amount
    ) external verifyParamsHash(keccak256(params)) {
        if (msg.sender != _getUserWithdrawAddress(params)) revert Unauthorized();
        _transferOut(token, to, amount);
        emit UserWithdraw(token, to, amount);
    }

    /**
     * @dev Transfers native ETH (token == NATIVE_ASSET) or ERC20 tokens.
     * @param token ERC20 token address, or NATIVE_ASSET for native ETH.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     */
    function _transferOut(address token, address to, uint256 amount) internal {
        if (token == NATIVE_ASSET) {
            (bool success, ) = to.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function _getUserWithdrawAddress(bytes calldata params) internal pure virtual returns (address) {
        return abi.decode(params, (CounterfactualDepositGlobalConfig)).userWithdrawAddress;
    }

    function _getAdminWithdrawAddress(bytes calldata params) internal pure virtual returns (address) {
        return abi.decode(params, (CounterfactualDepositGlobalConfig)).adminWithdrawAddress;
    }
}
