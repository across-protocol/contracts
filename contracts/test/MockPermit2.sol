pragma solidity ^0.8.0;

import { IPermit2 } from "../external/interfaces/IPermit2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

// Taken from https://github.com/Uniswap/permit2/blob/main/src/EIP712.sol
contract Permit2EIP712 {
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;

    bytes32 private constant _HASHED_NAME = keccak256("Permit2");
    bytes32 private constant _TYPE_HASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    constructor() {
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME);
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            block.chainid == _CACHED_CHAIN_ID
                ? _CACHED_DOMAIN_SEPARATOR
                : _buildDomainSeparator(_TYPE_HASH, _HASHED_NAME);
    }

    function _buildDomainSeparator(bytes32 typeHash, bytes32 nameHash) private view returns (bytes32) {
        return keccak256(abi.encode(typeHash, nameHash, block.chainid, address(this)));
    }

    function _hashTypedData(bytes32 dataHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), dataHash));
    }
}

contract MockPermit2 is IPermit2, Permit2EIP712 {
    using SafeERC20 for IERC20;

    mapping(address => mapping(uint256 => uint256)) public nonceBitmap;
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;

    bytes32 public constant _TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    string public constant _PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    error SignatureExpired();
    error InvalidAmount();
    error InvalidNonce();
    error AllowanceExpired();
    error InsufficientAllowance();

    function permitWitnessTransferFrom(
        PermitTransferFrom memory _permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external override {
        _permitTransferFrom(
            _permit,
            transferDetails,
            owner,
            hashWithWitness(_permit, witness, witnessTypeString),
            signature
        );
    }

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external {
        _transfer(from, to, amount, token);
    }

    // This is not a copy of permit2's permit.
    function permit(
        address owner,
        PermitSingle memory permitSingle,
        bytes calldata signature
    ) external {
        if (block.timestamp > permitSingle.sigDeadline) revert SignatureExpired();

        // Verify the signer address from the signature.
        SignatureVerification.verify(signature, _hashTypedData(keccak256(abi.encode(permitSingle))), owner);

        allowance[owner][permitSingle.details.token][permitSingle.spender] = permitSingle.details.amount;
    }

    // This is not a copy of permit2's permit.
    function _transfer(
        address from,
        address to,
        uint160 amount,
        address token
    ) private {
        uint256 allowed = allowance[from][token][msg.sender];

        if (allowed != type(uint160).max) {
            if (amount > allowed) {
                revert InsufficientAllowance();
            } else {
                unchecked {
                    allowance[from][token][msg.sender] = uint160(allowed) - amount;
                }
            }
        }

        // Transfer the tokens from the from address to the recipient.
        IERC20(token).safeTransferFrom(from, to, amount);
    }

    function _permitTransferFrom(
        PermitTransferFrom memory _permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 dataHash,
        bytes calldata signature
    ) private {
        uint256 requestedAmount = transferDetails.requestedAmount;

        if (block.timestamp > _permit.deadline) revert SignatureExpired();
        if (requestedAmount > _permit.permitted.amount) revert InvalidAmount();

        _useUnorderedNonce(owner, _permit.nonce);

        SignatureVerification.verify(signature, _hashTypedData(dataHash), owner);

        IERC20(_permit.permitted.token).safeTransferFrom(owner, transferDetails.to, requestedAmount);
    }

    function bitmapPositions(uint256 nonce) private pure returns (uint256 wordPos, uint256 bitPos) {
        wordPos = uint248(nonce >> 8);
        bitPos = uint8(nonce);
    }

    function _useUnorderedNonce(address from, uint256 nonce) internal {
        (uint256 wordPos, uint256 bitPos) = bitmapPositions(nonce);
        uint256 bit = 1 << bitPos;
        uint256 flipped = nonceBitmap[from][wordPos] ^= bit;

        if (flipped & bit == 0) revert InvalidNonce();
    }

    function hashWithWitness(
        PermitTransferFrom memory _permit,
        bytes32 witness,
        string calldata witnessTypeString
    ) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(abi.encodePacked(_PERMIT_TRANSFER_FROM_WITNESS_TYPEHASH_STUB, witnessTypeString));

        bytes32 tokenPermissionsHash = _hashTokenPermissions(_permit.permitted);
        return
            keccak256(abi.encode(typeHash, tokenPermissionsHash, msg.sender, _permit.nonce, _permit.deadline, witness));
    }

    function _hashTokenPermissions(TokenPermissions memory permitted) private pure returns (bytes32) {
        return keccak256(abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permitted));
    }
}

// Taken from https://github.com/Uniswap/permit2/blob/main/src/libraries/SignatureVerification.sol
library SignatureVerification {
    error InvalidSignatureLength();
    error InvalidSignature();
    error InvalidSigner();
    error InvalidContractSignature();

    bytes32 constant UPPER_BIT_MASK = (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);

    function verify(
        bytes calldata signature,
        bytes32 hash,
        address claimedSigner
    ) internal view {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (claimedSigner.code.length == 0) {
            if (signature.length == 65) {
                (r, s) = abi.decode(signature, (bytes32, bytes32));
                v = uint8(signature[64]);
            } else if (signature.length == 64) {
                // EIP-2098
                bytes32 vs;
                (r, vs) = abi.decode(signature, (bytes32, bytes32));
                s = vs & UPPER_BIT_MASK;
                v = uint8(uint256(vs >> 255)) + 27;
            } else {
                revert InvalidSignatureLength();
            }
            address signer = ecrecover(hash, v, r, s);
            if (signer == address(0)) revert InvalidSignature();
            if (signer != claimedSigner) revert InvalidSigner();
        } else {
            bytes4 magicValue = IERC1271(claimedSigner).isValidSignature(hash, signature);
            if (magicValue != IERC1271.isValidSignature.selector) revert InvalidContractSignature();
        }
    }
}
