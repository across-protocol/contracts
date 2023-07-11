// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/HubPoolInterface.sol";
import "./external/WETH9.sol";

interface ExtendedHubPoolInterface is HubPoolInterface {
    // Specify the automatically-implemented rootBundleProposal() getter.
    function rootBundleProposal() external pure returns (HubPoolInterface.RootBundle memory);
}

/**
 * @notice Across Bond Token (ABT).
 * ABT is a simple deposit contract based on WETH9. ABT is issued proportionally to any address that deposits Ether. It
 * imposes address-based permissioning on the WETH9 transferFrom() function in order to constrain the movement of ABT
 * into the Across v2 HubPool contract. When configured as the required HubPool bond token, ABT can dramatically reduce
 * the attack surface of the HubPool by requiring that addresses are explicitly approved before they can successfully
 * submit a root bundle proposal. The address-based permissioning does not constrain transfers that are needed to dispute
 * a root bundle proposal, so the ability of decentralised/unknown actors to dispute is unaffected.
 */
contract BondToken is WETH9, Ownable {
    using Address for address;

    ExtendedHubPoolInterface public immutable hubPool;

    /**
     * @notice Addresses that are permitted to make HubPool root bundle proposals.
     */
    mapping(address => bool) public proposers;

    /**
     * @notice Emitted on proposer permissions update.
     */
    event ProposerModified(address proposer, bool enabled);

    /**
     * @notice BondToken constructor.
     * @param _hubPool Address of the target HubPool contract.
     */
    constructor(ExtendedHubPoolInterface _hubPool) {
        name = "Across Bond Token";
        symbol = "ABT";
        hubPool = _hubPool;
    }

    /**
     * @notice Enable or disable an address as an allowed proposer. Emits a "ProposerModified" event on completion.
     * @param proposer Proposer address to modify.
     * @param enabled Boolean controlling whether the address is permitted to propose.
     */
    function setProposer(address proposer, bool enabled) external onlyOwner {
        proposers[proposer] = enabled;
        emit ProposerModified(proposer, enabled);
    }

    /**
     * @notice Transfer amt from src to dst. Prevents unauthorised root bundle proposals by blocking transfers to the
     * HubPool under the following conditions:
     * - The src address is not a pre-approved proposer, *and*
     * - The src address is the current proposer of a HubPool root bundle.
     * Falls back to the base implementation after verifying that the transfer is permitted.
     * @dev The require(..., "Transfer not permitted") statement is dependent on the internal ordering of HubPool
     * proposedRootBundle state variable updates, relative to calling bondToken.safeTransferFrom(). Changing the order
     * of HubPool actions may invalidate this verification. BondToken tests are implemented to detect this.
     * @param src Source address.
     * @param dst Destination address.
     * @param amt Amount to transfer.
     * @return True on success.
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amt
    ) public override returns (bool) {
        if (dst == address(hubPool)) {
            require(proposers[src] || hubPool.rootBundleProposal().proposer != src, "Transfer not permitted");
        }
        return super.transferFrom(src, dst, amt);
    }
}
