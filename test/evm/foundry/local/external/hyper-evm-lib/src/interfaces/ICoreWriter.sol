// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}
