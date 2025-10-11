//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

/**
 * @title SponsoredCCTPInterface
 * @notice Interface for the SponsoredCCTP contract
 * @custom:security-contact bugs@across.to
 */
interface SponsoredCCTPInterface {
    // Params that will be used to create a sponsored CCTP quote and deposit for burn.
    struct SponsoredCCTPQuote {
        // The domain ID of the source chain.
        uint32 sourceDomain;
        // The domain ID of the destination chain.
        uint32 destinationDomain;
        // The recipient of the minted USDC on the destination chain.
        bytes32 mintRecipient;
        // The amount that the user pays on the source chain.
        uint256 amount;
        // The token that will be burned on the source chain.
        address burnToken;
        // The caller of the destination chain.
        bytes32 destinationCaller;
        // Maximum fee to pay on the destination domain, specified in units of burnToken
        uint256 maxFee;
        // Minimum finality threshold before allowed to attest
        uint32 minFinalityThreshold;
        // Nonce is used to prevent replay attacks.
        bytes32 nonce;
        // Timestamp of the quote after which it can no longer be used.
        uint256 deadline;
        // MaxSponsoredAmount is the maximum amount that can be sponsored for the quote.
        uint256 maxSponsoredAmount;
        // The final recipient of the sponsored deposit. This is needed as the mintRecipient will be the
        // handler contract address instead of the final recipient.
        bytes32 finalRecipient;
        // The final token that final recipient will receive. This is needed as it can be different from the burnToken
        // in which case we perform a swap on the destination chain.
        bytes32 finalToken;
    }
}
