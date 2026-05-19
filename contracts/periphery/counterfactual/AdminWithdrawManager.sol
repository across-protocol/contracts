// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @title AdminWithdrawManager
 * @notice Manages admin withdrawals from counterfactual deposit clones via two paths:
 *           1. Direct withdraw — trusted `directWithdrawer` calls with caller-chosen recipient.
 *           2. Signed withdraw — anyone can trigger with a valid `signer` signature; the signer
 *              fixes the recipient via the EIP-712 message.
 * @dev To use, set `cloneArgs.withdrawUser = address(this)` at clone-deploy time. The dispatcher's
 *      structural withdraw escape then trusts this contract as the sole withdraw authority and
 *      bypasses the merkle proof entirely.
 * @custom:security-contact bugs@across.to
 */
contract AdminWithdrawManager is Ownable, EIP712 {
    /// @notice Emitted when the direct withdrawer address is updated.
    event DirectWithdrawerUpdated(address indexed directWithdrawer);

    /// @notice Emitted when the signer address is updated.
    event SignerUpdated(address indexed signer);

    error Unauthorized();
    error InvalidSignature();
    error SignatureExpired();

    /// @notice EIP-712 typehash for signed withdraw messages. The signer fixes `to`.
    bytes32 public constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256("SignedWithdraw(address depositAddress,address token,address to,uint256 amount,uint256 deadline)");

    /// @notice Canonical `WithdrawImplementation` address (passed to the dispatcher's escape path).
    address public immutable withdrawImpl;

    /// @notice Address authorized to call `directWithdraw` without a signature.
    address public directWithdrawer;

    /// @notice Address whose EIP-712 signature authorizes `signedWithdraw` calls.
    address public signer;

    constructor(
        address _owner,
        address _directWithdrawer,
        address _signer,
        address _withdrawImpl
    ) Ownable(_owner) EIP712("AdminWithdrawManager", "v1.0.0") {
        directWithdrawer = _directWithdrawer;
        signer = _signer;
        withdrawImpl = _withdrawImpl;
    }

    /**
     * @notice Direct withdraw — calls `clone.execute()` against the dispatcher's withdraw escape.
     * @dev Only callable by `directWithdrawer`. Recipient (`to`) is chosen by the caller.
     */
    function directWithdraw(
        address depositAddress,
        CloneArgs calldata cloneArgs,
        address token,
        address to,
        uint256 amount
    ) external {
        if (msg.sender != directWithdrawer) revert Unauthorized();
        ICounterfactualDeposit(depositAddress).execute(
            cloneArgs,
            withdrawImpl,
            "",
            abi.encode(token, to, amount),
            new bytes32[](0)
        );
    }

    /**
     * @notice Signed withdraw — anyone can trigger with a valid `signer` signature.
     * @dev The signer fixes the recipient (`to`) in the EIP-712 message; the caller cannot redirect.
     */
    function signedWithdraw(
        address depositAddress,
        CloneArgs calldata cloneArgs,
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, token, to, amount, deadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();

        ICounterfactualDeposit(depositAddress).execute(
            cloneArgs,
            withdrawImpl,
            "",
            abi.encode(token, to, amount),
            new bytes32[](0)
        );
    }

    /// @notice Updates the direct withdrawer address.
    function setDirectWithdrawer(address _directWithdrawer) external onlyOwner {
        directWithdrawer = _directWithdrawer;
        emit DirectWithdrawerUpdated(_directWithdrawer);
    }

    /// @notice Updates the signer address used for signed withdrawals.
    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerUpdated(_signer);
    }
}
