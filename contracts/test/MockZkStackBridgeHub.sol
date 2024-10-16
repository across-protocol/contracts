// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { BridgeHubInterface } from "../interfaces/ZkStackBridgeHub.sol";

contract MockBridgeHub is BridgeHubInterface {
    address public immutable sharedBridge;

    constructor(address _sharedBridge) {
        sharedBridge = _sharedBridge;
    }

    mapping(uint256 => address) baseTokens;

    function setBaseToken(uint256 _chainId, address _baseToken) external {
        baseTokens[_chainId] = _baseToken;
    }

    function requestL2TransactionDirect(L2TransactionRequestDirect calldata _request)
        external
        payable
        returns (bytes32 canonicalTxHash)
    {
        canonicalTxHash = keccak256(abi.encode(_request));
    }

    function requestL2TransactionTwoBridges(L2TransactionRequestTwoBridgesOuter calldata _request)
        external
        payable
        returns (bytes32 canonicalTxHash)
    {
        canonicalTxHash = keccak256(abi.encode(_request));
    }

    function baseToken(uint256 _chainId) external view returns (address) {
        return baseTokens[_chainId] == address(0) ? address(1) : baseTokens[_chainId];
    }

    function l2TransactionBaseCost(
        uint256,
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) external view returns (uint256) {
        return _gasPrice + _l2GasLimit * _l2GasPerPubdataByteLimit;
    }
}
