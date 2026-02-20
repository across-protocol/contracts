// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";

/**
 * @title AdminWithdrawManager
 * @notice Manages admin withdrawals from counterfactual deposit clones via two paths:
 *         1. Direct withdraw — trusted `directWithdrawer` specifies any recipient
 *         2. Signed withdraw — anyone can trigger with a `signer` signature; recipient is always the clone's userWithdrawAddress
 * @dev Set this contract's address as `adminWithdrawAddress` on clones.
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

    /**
     * @param _owner Contract owner (can update directWithdrawer and signer).
     * @param _directWithdrawer Initial direct withdrawer address.
     * @param _signer Initial signer address for signed withdrawals.
     */
    constructor(
        address _owner,
        address _directWithdrawer,
        address _signer
    ) Ownable(_owner) EIP712("AdminWithdrawManager", "v1.0.0") {
        directWithdrawer = _directWithdrawer;
        signer = _signer;
    }

    /**
     * @notice Direct withdraw — forwards raw calldata to the deposit clone.
     * @dev Only callable by `directWithdrawer`. Caller encodes the implementation-specific adminWithdraw call.
     * @param depositAddress Address of the deployed clone.
     * @param adminWithdrawCalldata Encoded call to adminWithdraw on the clone.
     */
    function directWithdraw(address depositAddress, bytes calldata adminWithdrawCalldata) external {
        if (msg.sender != directWithdrawer) revert Unauthorized();
        (bool success, bytes memory returnData) = depositAddress.call(adminWithdrawCalldata);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }

    /**
     * @notice Signed withdraw to user — anyone can trigger with a valid signature from `signer`.
     * @dev Recipient is always the clone's `userWithdrawAddress` (enforced by adminWithdrawToUser).
     * @param depositAddress Address of the deployed clone.
     * @param paramsBytes ABI-encoded route parameters (passed to adminWithdrawToUser).
     * @param token ERC20 token to withdraw, or NATIVE_ASSET for native ETH.
     * @param amount Amount to withdraw.
     * @param deadline Timestamp after which the signature is no longer valid.
     * @param signature EIP-712 signature from `signer`.
     */
    function signedWithdrawToUser(
        address depositAddress,
        bytes calldata paramsBytes,
        address token,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, token, amount, deadline));
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();

        ICounterfactualDeposit(depositAddress).adminWithdrawToUser(paramsBytes, token, amount);
    }

    /**
     * @notice Updates the direct withdrawer address.
     * @param _directWithdrawer New direct withdrawer address.
     */
    function setDirectWithdrawer(address _directWithdrawer) external onlyOwner {
        directWithdrawer = _directWithdrawer;
        emit DirectWithdrawerUpdated(_directWithdrawer);
    }

    /**
     * @notice Updates the signer address used for signed withdrawals.
     * @param _signer New signer address.
     */
    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerUpdated(_signer);
    }
}
