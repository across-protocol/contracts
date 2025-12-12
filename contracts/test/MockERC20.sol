//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";
import { ERC20Permit } from "@openzeppelin/contracts-v4/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20 } from "@openzeppelin/contracts-v4/token/ERC20/ERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts-v4/utils/cryptography/SignatureChecker.sol";

/**
 * @title MintableERC20
 * @notice Simple mintable ERC20 with configurable decimals for testing.
 */
contract MintableERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

/**
 * @title MockERC20
 * @notice Implements mocked ERC20 contract with various features.
 */
contract MockERC20 is IERC20Auth, ERC20Permit {
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
    // Expose the typehash in ERC20Permit.
    bytes32 public constant PERMIT_TYPEHASH_EXTERNAL =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    constructor() ERC20Permit("MockERC20") ERC20("MockERC20", "ERC20") {}

    // This does no nonce checking.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(validAfter <= block.timestamp && validBefore >= block.timestamp, "Invalid time bounds");
        require(msg.sender == to, "Receiver not caller");
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce)
        );
        bytes32 sigHash = _hashTypedDataV4(structHash);
        require(SignatureChecker.isValidSignatureNow(from, sigHash, signature), "Invalid signature");
        _transfer(from, to, value);
    }

    function hashTypedData(bytes32 typedData) external view returns (bytes32) {
        return _hashTypedDataV4(typedData);
    }
}
