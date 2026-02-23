// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title AdminWithdrawManager
 * @notice Manages admin withdrawals from counterfactual deposit clones via two paths:
 *         1. Direct withdraw — trusted `directWithdrawer` calls clone.execute() with arbitrary submitterData
 *         2. Signed withdraw — anyone can trigger with a `signer` signature; recipient is forced to the user
 * @dev Set this contract's address as `authorizedCaller` in withdrawal merkle leaves.
 */
contract AdminWithdrawManager is Ownable, EIP712 {
    event DirectWithdrawerUpdated(address indexed directWithdrawer);
    event SignerUpdated(address indexed signer);

    error Unauthorized();
    error InvalidSignature();
    error SignatureExpired();

    bytes32 public constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256("SignedWithdraw(address depositAddress,address token,uint256 amount,uint256 deadline)");

    address public directWithdrawer;
    address public signer;

    constructor(
        address _owner,
        address _directWithdrawer,
        address _signer
    ) Ownable(_owner) EIP712("AdminWithdrawManager", "v1.0.0") {
        directWithdrawer = _directWithdrawer;
        signer = _signer;
    }

    /**
     * @notice Direct withdraw — calls clone.execute() with the provided parameters.
     * @dev Only callable by `directWithdrawer`. Caller provides all merkle proof data.
     * @param depositAddress Address of the deployed clone.
     * @param implementation WithdrawImplementation address (merkle leaf implementation).
     * @param params ABI-encoded WithdrawParams (authorizedCaller must be this contract).
     * @param submitterData ABI-encoded (token, to, amount) for the withdrawal.
     * @param proof Merkle proof for the withdrawal leaf.
     */
    function directWithdraw(
        address depositAddress,
        address implementation,
        bytes calldata params,
        bytes calldata submitterData,
        bytes32[] calldata proof
    ) external {
        if (msg.sender != directWithdrawer) revert Unauthorized();
        ICounterfactualDeposit(depositAddress).execute(implementation, params, submitterData, proof);
    }

    /**
     * @notice Signed withdraw to user — anyone can trigger with a valid signature from `signer`.
     * @dev The `submitterData` must encode `(token, forcedRecipient, amount)` where forcedRecipient matches
     *      the WithdrawParams.forcedRecipient committed in the merkle leaf.
     * @param depositAddress Address of the deployed clone.
     * @param implementation WithdrawImplementation address (merkle leaf implementation).
     * @param params ABI-encoded WithdrawParams (authorizedCaller = this, forcedRecipient = user).
     * @param token Token to withdraw.
     * @param to Recipient (must match forcedRecipient in params).
     * @param amount Amount to withdraw.
     * @param proof Merkle proof for the withdrawal leaf.
     * @param deadline Timestamp after which the signature is no longer valid.
     * @param signature EIP-712 signature from `signer`.
     */
    function signedWithdrawToUser(
        address depositAddress,
        address implementation,
        bytes calldata params,
        address token,
        address to,
        uint256 amount,
        bytes32[] calldata proof,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, token, amount, deadline));
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();

        ICounterfactualDeposit(depositAddress).execute(implementation, params, abi.encode(token, to, amount), proof);
    }

    function setDirectWithdrawer(address _directWithdrawer) external onlyOwner {
        directWithdrawer = _directWithdrawer;
        emit DirectWithdrawerUpdated(_directWithdrawer);
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerUpdated(_signer);
    }
}
