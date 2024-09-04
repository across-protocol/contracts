// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev https://eips.ethereum.org/EIPS/eip-712[EIP 712] is a standard for hashing and signing of typed structured data.
 *
 * This contract is based on OpenZeppelin's implementation:
 * https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/master/contracts/utils/cryptography/EIP712Upgradeable.sol
 *
 * NOTE: Modified version that allows to build a domain separator that relies on a different chain id than the chain this
 * contract is deployed to. An example use case we want to support is:
 * - User A signs a message on chain with id = 1
 * - User B executes a method by verifying user A's EIP-712 compliant signature on a chain with id != 1
 * @custom:security-contact bugs@across.to
 */
abstract contract EIP712CrossChainUpgradeable is Initializable {
    /* solhint-disable var-name-mixedcase */
    bytes32 private _HASHED_NAME;
    bytes32 private _HASHED_VERSION;
    bytes32 private constant _TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId)");

    /* solhint-enable var-name-mixedcase */

    /**
     * @dev Initializes the domain separator and parameter caches.
     *
     * The meaning of `name` and `version` is specified in
     * https://eips.ethereum.org/EIPS/eip-712#definition-of-domainseparator[EIP 712]:
     *
     * - `name`: the user readable name of the signing domain, i.e. the name of the DApp or the protocol.
     * - `version`: the current major version of the signing domain.
     *
     * NOTE: These parameters cannot be changed except through a xref:learn::upgrading-smart-contracts.adoc[smart
     * contract upgrade].
     */
    function __EIP712_init(string memory name, string memory version) internal onlyInitializing {
        __EIP712_init_unchained(name, version);
    }

    function __EIP712_init_unchained(string memory name, string memory version) internal onlyInitializing {
        bytes32 hashedName = keccak256(bytes(name));
        bytes32 hashedVersion = keccak256(bytes(version));
        _HASHED_NAME = hashedName;
        _HASHED_VERSION = hashedVersion;
    }

    /**
     * @dev Returns the domain separator depending on the `originChainId`.
     * @param originChainId Chain id of network where message originates from.
     * @return bytes32 EIP-712-compliant domain separator.
     */
    function _domainSeparatorV4(uint256 originChainId) internal view returns (bytes32) {
        return keccak256(abi.encode(_TYPE_HASH, _HASHED_NAME, _HASHED_VERSION, originChainId));
    }

    /**
     * @dev Given an already https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct[hashed struct], this
     * function returns the hash of the fully encoded EIP712 message for this domain.
     *
     * This hash can be used together with {ECDSA-recover} to obtain the signer of a message. For example:
     *
     * ```solidity
     * bytes32 structHash = keccak256(abi.encode(
     *     keccak256("Mail(address to,string contents)"),
     *     mailTo,
     *     keccak256(bytes(mailContents))
     * ));
     * bytes32 digest = _hashTypedDataV4(structHash, originChainId);
     * address signer = ECDSA.recover(digest, signature);
     * ```
     * @param structHash Hashed struct as defined in https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct.
     * @param originChainId Chain id of network where message originates from.
     * @return bytes32 Hash digest that is recoverable via `EDCSA.recover`.
     */
    function _hashTypedDataV4(bytes32 structHash, uint256 originChainId) internal view virtual returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(_domainSeparatorV4(originChainId), structHash);
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[1000] private __gap;
}
