// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

struct MulticallCall {
    address target;
    bytes callData;
    uint256 value;
}

struct MulticallReplacement {
    address token;
    uint256 offset;
}

struct MulticallInstructions {
    MulticallCall[] calls;
    address fallbackRecipient;
}

struct BalanceReq {
    address token;
    uint256 minAmount;
    bool useFullBalance;
}

struct SubmitterReq {
    address submitter;
}

struct DeadlineReq {
    uint256 deadline;
}

enum AlterType {
    None,
    OffchainAuction,
    SimpleSubmitter
}

struct AlterConfig {
    AlterType typ;
    address auctionAuthority;
}

struct OffchainAuctionAlter {
    uint256 newMinAmount;
    address newSubmitter;
    uint256 deadline;
    bytes signature;
}

struct ExecutorV1SubmitterData {
    bytes alterData;
    bytes multicallData;
    uint256 finalActionValue;
}

enum FinalActionType {
    Transfer,
    Execute
}

struct FinalAction {
    FinalActionType typ;
    address target;
    address token;
    bytes message;
}

struct ExecutorStep {
    BalanceReq balanceReq;
    SubmitterReq submitterReq;
    DeadlineReq deadlineReq;
    AlterConfig alterConfig;
    FinalAction finalAction;
}
