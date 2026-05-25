// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ICounterfactualDeposit } from "../../interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "./CounterfactualCloneArgs.sol";

/**
 * @title AdminWithdrawManager
 * @notice Manages withdrawals from counterfactual deposit clones via two paths:
 *           1. Direct withdraw — trusted `directWithdrawer` triggers a withdrawal.
 *           2. Signed withdraw — anyone can trigger with a valid `signer` signature.
 *         Funds always land at `cloneArgs.userAddress` — neither path can choose recipient.
 *         Withdrawal authority is therefore "when and how much", not "where".
 * @dev The target `withdrawImpl` is supplied per call rather than stored on the manager. This
 *      avoids a circular construction dependency with `WithdrawImplementation` (which holds the
 *      manager's address as its immutable `admin`): the manager can be deployed first, then the
 *      impl is deployed pointing at the manager's known address. The dispatcher's merkle check
 *      ensures only policy-authorized impls can ever be reached, regardless of what address the
 *      caller passes.
 *
 *      To use, deploy this manager, then deploy `WithdrawImplementation` with this contract's
 *      address as its immutable `admin`. Include the `(withdrawImpl, "")` leaf in any policy
 *      whose clones should accept manager-driven withdrawals. The user's self-withdraw path
 *      (via `clone.execute` from `cloneArgs.userAddress`) is always available and doesn't go
 *      through this manager.
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

    /// @notice EIP-712 typehash for signed withdraw messages. The signature commits to the target
    ///         `withdrawImpl` so a submitter cannot redirect an authorized withdrawal to a
    ///         different impl. Recipient is not signed — it is fixed to `cloneArgs.userAddress`
    ///         by `WithdrawImplementation`.
    bytes32 public constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256(
            "SignedWithdraw(address depositAddress,address withdrawImpl,address token,uint256 amount,uint256 deadline)"
        );

    /// @notice Address authorized to call `directWithdraw` without a signature.
    address public directWithdrawer;

    /// @notice Address whose EIP-712 signature authorizes `signedWithdraw` calls.
    address public signer;

    constructor(
        address _owner,
        address _directWithdrawer,
        address _signer
    ) Ownable(_owner) EIP712("AdminWithdrawManager", "v2.0.0") {
        directWithdrawer = _directWithdrawer;
        signer = _signer;
    }

    /**
     * @notice Direct withdraw — triggers a sweep of `(token, amount)` from `depositAddress` to its
     *         bound `userAddress` via the supplied `withdrawImpl`.
     * @dev Only callable by `directWithdrawer`. Recipient is fixed by clone identity — the caller
     *      cannot redirect funds. The caller supplies both the impl and the merkle proof for the
     *      policy's withdraw leaf; the dispatcher verifies the proof before delegatecalling the
     *      impl, and the impl checks `msg.sender == admin` (= this manager).
     */
    function directWithdraw(
        address depositAddress,
        CloneArgs calldata cloneArgs,
        address withdrawImpl,
        address token,
        uint256 amount,
        bytes32[] calldata proof
    ) external {
        if (msg.sender != directWithdrawer) revert Unauthorized();
        ICounterfactualDeposit(depositAddress).execute(cloneArgs, withdrawImpl, "", abi.encode(token, amount), proof);
    }

    /**
     * @notice Signed withdraw — anyone can trigger with a valid `signer` signature over
     *         `(depositAddress, withdrawImpl, token, amount, deadline)`. Recipient is fixed to
     *         `cloneArgs.userAddress` inside `WithdrawImplementation`; a compromised signer can
     *         force withdrawals to happen but cannot redirect them. The submitter supplies the
     *         merkle proof for the policy's withdraw leaf (it is not part of what the signer
     *         authorizes — the tree is publicly known off-chain).
     */
    function signedWithdraw(
        address depositAddress,
        CloneArgs calldata cloneArgs,
        address withdrawImpl,
        address token,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature,
        bytes32[] calldata proof
    ) external {
        if (block.timestamp > deadline) revert SignatureExpired();

        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, withdrawImpl, token, amount, deadline)
        );
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();

        ICounterfactualDeposit(depositAddress).execute(cloneArgs, withdrawImpl, "", abi.encode(token, amount), proof);
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
