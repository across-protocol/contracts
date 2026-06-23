// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Ethereum_SpokePool.sol";
import "./SpokePoolV5.sol";

/**
 * @notice Ethereum L1 specific SpokePoolV5. Combines {Ethereum_SpokePool} (owner-based admin, direct token transfer
 * to the withdrawal recipient) with the Across V5 Gateway integration ({SpokePoolV5}: executor/adapter entrypoints).
 * @dev The chain logic and admin auth come from {Ethereum_SpokePool}; the V5 deposit/fill behavior comes from
 * {SpokePoolV5}. Their overrides are disjoint, so no further resolution is required.
 *
 * @dev {SpokePoolV5} adds no initializer (the Gateway is an immutable set in the constructor), so initialization is
 * identical to {Ethereum_SpokePool}. Inserting the mixin only shifts the C3 linearization, which trips the OZ
 * Upgrades `incorrect-initializer-order` heuristic even though the inherited `__SpokePool_init` sequence is unchanged
 * and already validated for the production Ethereum pool — hence the allow below.
 * @custom:oz-upgrades-unsafe-allow incorrect-initializer-order
 * @custom:security-contact bugs@across.to
 */
contract Ethereum_SpokePoolV5 is Ethereum_SpokePool, SpokePoolV5 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _gateway,
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    )
        Ethereum_SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
        SpokePoolV5(_gateway)
    {} // solhint-disable-line no-empty-blocks

    // --- Diamond inheritance resolution ---
    // SpokePool defines these internals and SpokePoolV5 overrides them, so the concrete pool must disambiguate by
    // routing each to the SpokePoolV5 implementation (which itself delegates to SpokePool via `super`).

    function _pullDepositFunds(DepositV3Params memory params) internal override(SpokePool, SpokePoolV5) {
        SpokePoolV5._pullDepositFunds(params);
    }

    function _fillRelayV3(
        V3RelayExecutionParams memory relayExecution,
        bytes32 relayer,
        bool isSlowFill
    ) internal override(SpokePool, SpokePoolV5) {
        SpokePoolV5._fillRelayV3(relayExecution, relayer, isSlowFill);
    }

    function _transferTokensToRecipient(
        V3RelayExecutionParams memory relayExecution,
        V3RelayData memory relayData,
        bool isSlowFill
    ) internal override(SpokePool, SpokePoolV5) {
        SpokePoolV5._transferTokensToRecipient(relayExecution, relayData, isSlowFill);
    }
}
