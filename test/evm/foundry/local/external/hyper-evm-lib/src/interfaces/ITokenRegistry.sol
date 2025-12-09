// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ITokenRegistry {
    function getTokenIndex(address evmContract) external view returns (uint32 index);
}
