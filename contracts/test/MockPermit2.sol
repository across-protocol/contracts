pragma solidity ^0.8.0;

import { IPermit2 } from "../external/interfaces/IPermit2.sol";

contract MockPermit2 is IPermit2 {
    function permitWitnessTransferFrom(
        PermitTransferFrom memory _permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external override {
        // do nothing
    }

    function transferFrom(
        address from,
        address to,
        uint160 amount,
        address token
    ) external override {
        // do nothing
    }

    function permit(
        address owner,
        PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external override {
        // do nothing
    }
}
