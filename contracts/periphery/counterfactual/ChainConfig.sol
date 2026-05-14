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

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Set or clear a bridge address by id. Pass `address(0)` to clear.
    function setBridge(uint32 id, address addr) external onlyOwner {
        bridges[id] = addr;
        emit BridgeSet(id, addr);
    }

    /// @notice Set or clear a token address by id. Pass `address(0)` to clear.
    function setToken(uint32 id, address addr) external onlyOwner {
        tokens[id] = addr;
        emit TokenSet(id, addr);
    }

    function setCctpSourceDomain(uint32 value) external onlyOwner {
        cctpSourceDomain = value;
        emit CctpSourceDomainSet(value);
    }

    function setOftSrcEid(uint32 value) external onlyOwner {
        oftSrcEid = value;
        emit OftSrcEidSet(value);
    }

    function setSigner(address newSigner) external onlyOwner {
        signer = newSigner;
        emit SignerSet(newSigner);
    }
}
