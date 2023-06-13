// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../SpokePool.sol";

contract AcrossGenericHandler is AcrossMessageHandler {
    using SafeERC20 for IERC20;

    address public immutable spokePool;

    constructor(address spokePool_) {
        spokePool = spokePool_;
    }

    mapping(address => AcrossDelegateCaller) public instances;

    function handleAcrossMessage(
        address tokenSent,
        uint256 amount,
        bool fillCompleted,
        address relayer,
        bytes memory message
    ) external override {
        AcrossDelegateCaller delegateCaller = instances[relayer];
        // Okay to call _hasCode on 0x0, since it has no code.
        // Second check just in case there are weird chains with code at 0x0.
        if (!_hasCode(address(delegateCaller)) || address(delegateCaller) == address(0)) {
            // Each relayer has their own address. It doesn't change even if someone selfdestructs it.
            delegateCaller = new AcrossDelegateCaller{ salt: bytes32(uint256(uint160(relayer))) }();
            instances[relayer] = delegateCaller;
        }

        IERC20(tokenSent).safeTransfer(address(delegateCaller), amount);
        delegateCaller.execute(IERC20(tokenSent), amount, fillCompleted, relayer, message);
    }

    function _hasCode(address account) public view returns (bool) {
        // This method relies on extcodesize, which returns 0 for contracts in
        // construction, since the code is only stored at the end of the
        // constructor execution.
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size > 0;
    }
}

contract AcrossDelegateCaller {
    address public immutable creator;

    constructor() {
        creator = msg.sender;
    }

    IERC20 public token;
    uint256 public amount;
    bool public fillCompleted;
    address public relayer;

    function execute(
        IERC20 _tokenSent,
        uint256 _amount,
        bool _fillCompleted,
        address _relayer,
        bytes memory message
    ) external {
        require(msg.sender == creator, "can only be called by creator");
        // Set values so they can be requested during execution.
        (token, amount, fillCompleted, relayer) = (_tokenSent, _amount, _fillCompleted, _relayer);
        (address target, bytes memory callData) = abi.decode(message, (address, bytes));
        (bool success, ) = target.delegatecall(callData);
        require(success, "delegatecall failed");
        // Reset them to get gas refunds.
        (token, amount, fillCompleted, relayer) = (IERC20(address(0)), 0, false, address(0));
    }
}
