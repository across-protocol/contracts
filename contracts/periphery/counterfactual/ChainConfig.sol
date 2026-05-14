// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title ChainConfig
 * @notice On-chain registry that resolves stable, chain-agnostic IDs to concrete addresses and
 *         scalars on the chain where it is deployed. Read by counterfactual deposit implementations
 *         (CCTP / OFT / SpokePool) at execute time so the impls themselves can be chain-agnostic —
 *         same bytecode, same constructor arg (this registry), same deterministic address on
 *         every EVM chain.
 *
 * @dev    One instance per chain. Owner is intended to be a timelock-wrapped multisig; mutations
 *         are observable via events so users can react before a change takes effect.
 *
 *         The registry is mutable in storage but NOT upgradeable in bytecode. All operational
 *         changes we care about (bridge upgrades, token migrations, new IDs) are storage mutations.
 *
 *         Implementations consuming this registry MUST handle `address(0)` defensively — typically
 *         by reverting on lookup of an unset ID rather than silently passing a zero address to
 *         downstream `transferFrom` / `forceApprove` calls.
 *
 * @custom:security-contact bugs@across.to
 */
contract ChainConfig is Ownable2Step {
    /// @notice Emitted when a bridge address is set or cleared.
    event BridgeSet(uint32 indexed id, address indexed addr);
    /// @notice Emitted when a token address is set or cleared.
    event TokenSet(uint32 indexed id, address indexed addr);
    /// @notice Emitted when the CCTP source domain is set.
    event CctpSourceDomainSet(uint32 value);
    /// @notice Emitted when the OFT source endpoint id is set.
    event OftSrcEidSet(uint32 value);
    /// @notice Emitted when the signer is set.
    event SignerSet(address indexed signer);

    error LengthMismatch();

    /// @notice Bridge address by stable, chain-agnostic id (see ChainConfigIds.sol).
    mapping(uint32 id => address addr) public bridges;
    /// @notice Token address by stable, chain-agnostic id (see ChainConfigIds.sol).
    mapping(uint32 id => address addr) public tokens;

    /// @notice CCTP source domain id for this chain. Used by CounterfactualDepositCCTP.
    uint32 public cctpSourceDomain;
    /// @notice LayerZero source endpoint id for this chain. Used by CounterfactualDepositOFT.
    uint32 public oftSrcEid;
    /// @notice Signer authorized to issue execution-fee envelope signatures consumed by all
    ///         counterfactual deposit implementations (SpokePool, CCTP, OFT).
    address public signer;

    /**
     * @notice Deploys the registry pre-populated with the supplied bridges, tokens, and scalars.
     *         Any field can be left at its zero value (empty arrays for bridges/tokens, `0` for
     *         scalars, `address(0)` for signer) and configured later via the corresponding setter.
     * @param _owner Initial owner. Intended to be a timelock-wrapped multisig.
     * @param bridgeIds  Bridge ids to populate. Must match `bridgeAddrs` in length.
     * @param bridgeAddrs Bridge addresses at the corresponding ids.
     * @param tokenIds   Token ids to populate. Must match `tokenAddrs` in length.
     * @param tokenAddrs Token addresses at the corresponding ids.
     * @param _cctpSourceDomain Initial CCTP source domain id.
     * @param _oftSrcEid Initial LayerZero source endpoint id.
     * @param _signer Initial signer address.
     */
    constructor(
        address _owner,
        uint32[] memory bridgeIds,
        address[] memory bridgeAddrs,
        uint32[] memory tokenIds,
        address[] memory tokenAddrs,
        uint32 _cctpSourceDomain,
        uint32 _oftSrcEid,
        address _signer
    ) Ownable(_owner) {
        if (bridgeIds.length != bridgeAddrs.length) revert LengthMismatch();
        for (uint256 i; i < bridgeIds.length; ++i) {
            _setBridge(bridgeIds[i], bridgeAddrs[i]);
        }
        if (tokenIds.length != tokenAddrs.length) revert LengthMismatch();
        for (uint256 i; i < tokenIds.length; ++i) {
            _setToken(tokenIds[i], tokenAddrs[i]);
        }
        _setCctpSourceDomain(_cctpSourceDomain);
        _setOftSrcEid(_oftSrcEid);
        _setSigner(_signer);
    }

    /// @notice Set or clear a bridge address by id. Pass `address(0)` to clear.
    function setBridge(uint32 id, address addr) external onlyOwner {
        _setBridge(id, addr);
    }

    /// @notice Batch variant of `setBridge`. `ids` and `addrs` must be the same length.
    function setBridges(uint32[] calldata ids, address[] calldata addrs) external onlyOwner {
        if (ids.length != addrs.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            _setBridge(ids[i], addrs[i]);
        }
    }

    /// @notice Set or clear a token address by id. Pass `address(0)` to clear.
    function setToken(uint32 id, address addr) external onlyOwner {
        _setToken(id, addr);
    }

    /// @notice Batch variant of `setToken`. `ids` and `addrs` must be the same length.
    function setTokens(uint32[] calldata ids, address[] calldata addrs) external onlyOwner {
        if (ids.length != addrs.length) revert LengthMismatch();
        for (uint256 i; i < ids.length; ++i) {
            _setToken(ids[i], addrs[i]);
        }
    }

    function setCctpSourceDomain(uint32 value) external onlyOwner {
        _setCctpSourceDomain(value);
    }

    function setOftSrcEid(uint32 value) external onlyOwner {
        _setOftSrcEid(value);
    }

    function setSigner(address newSigner) external onlyOwner {
        _setSigner(newSigner);
    }

    function _setBridge(uint32 id, address addr) private {
        bridges[id] = addr;
        emit BridgeSet(id, addr);
    }

    function _setToken(uint32 id, address addr) private {
        tokens[id] = addr;
        emit TokenSet(id, addr);
    }

    function _setCctpSourceDomain(uint32 value) private {
        cctpSourceDomain = value;
        emit CctpSourceDomainSet(value);
    }

    function _setOftSrcEid(uint32 value) private {
        oftSrcEid = value;
        emit OftSrcEidSet(value);
    }

    function _setSigner(address newSigner) private {
        signer = newSigner;
        emit SignerSet(newSigner);
    }
}
