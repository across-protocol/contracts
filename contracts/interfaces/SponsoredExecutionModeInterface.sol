// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @notice Shared execution modes for sponsored bridging flows.
 */
interface SponsoredExecutionModeInterface {
    // Send to core and perform swap (if needed) there.
    enum ExecutionMode {
        DirectToCore,
        // Execute arbitrary actions (like a swap) on HyperEVM, then transfer to HyperCore.
        ArbitraryActionsToCore,
        // Execute arbitrary actions on HyperEVM only (no HyperCore transfer).
        ArbitraryActionsToEVM
    }
}
