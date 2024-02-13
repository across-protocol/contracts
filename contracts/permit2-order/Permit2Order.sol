// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// General Settlement Info.
struct SettlementInfo {
    // The contract intended for settlement.
    address settlerContract;
    // User who created the order.
    address offerer;
    // The nonce of the order for replay protection.
    uint256 nonce;
    // Latest timestamp at which the order can be brought onchain.
    uint256 initiateDeadline;
    // Max delay between the order being brought onchain and the fill.
    uint32 fillPeriod;
    // The rest of the fields are unused in Across.
    uint32 challengePeriod;
    uint32 proofPeriod;
    address settlementOracle;
    address validationContract;
    bytes validationData;
}

// Input token info.
struct InputToken {
    address token;
    uint256 amount;
    uint256 maxAmount;
}

// Callateral token info.
struct CollateralToken {
    address token;
    uint256 amount;
}

// Output information.
struct OutputToken {
    address recipient;
    address token;
    uint256 amount;
    uint256 chainId;
}

// Full order struct that the user signs.
struct CrossChainLimitOrder {
    // General order info.
    SettlementInfo info;
    // User's input token.
    InputToken input;
    // Filler's provided collateral.
    CollateralToken fillerCollateral;
    // Unused in Across.
    CollateralToken challengerCollateral;
    // Outputs. Today, Across only supports a single output.
    OutputToken[] outputs;
}

// Encoded order + Permit2 signature.
struct SignedOrder {
    bytes order;
    bytes sig;
}
