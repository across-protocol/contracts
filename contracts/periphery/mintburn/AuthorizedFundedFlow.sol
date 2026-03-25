// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

/// @notice Library shared between handler contracts and modules to communicate from handler to module what context is a
/// specific function being called in
abstract contract AuthorizedFundedFlow {
    // keccak256(abi.encode(uint256(keccak256("erc7201:AuthorizedFundedFlow.bool")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 public constant AUTHORIZED_FUNDED_FLOW_SLOT =
        0xc56a3250645180a53cd9e196b2ee0a634a4f54e2edf59ea457f2083917e4d100;

    error FundedFlowNotAuthorized();

    modifier authorizeFundedFlow() {
        bytes32 slot = AUTHORIZED_FUNDED_FLOW_SLOT;
        assembly {
            sstore(slot, 1)
        }
        _;
        assembly {
            sstore(slot, 0)
        }
    }

    modifier onlyAuthorizedFlow() {
        bytes32 slot = AUTHORIZED_FUNDED_FLOW_SLOT;
        bool authorized;
        assembly {
            authorized := sload(slot)
        }
        if (!authorized) {
            revert FundedFlowNotAuthorized();
        }
        _;
    }
}
