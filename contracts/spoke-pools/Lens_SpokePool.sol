// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./ZkSync_SpokePool.sol";

/**
 * @notice Lens specific SpokePool. Wrapper around the ZkSync_SpokePool contract.
 * @dev Resources for compiling and deploying ZkSync contracts: https://docs.zksync.io/build/tooling/foundry/overview
 * @custom:security-contact bugs@across.to
 * @dev This contract intentionally has no initializer of its own. Proxies are initialized via the
 * inherited ZkSync_SpokePool.initialize, which the OZ missing-initializer heuristic does not recognize.
 * @custom:oz-upgrades-unsafe-allow missing-initializer
 */
contract Lens_SpokePool is ZkSync_SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        IERC20 _circleUSDC,
        ZkBridgeLike _zkUSDCBridge,
        uint256 _l1ChainId,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        address _gateway
    )
        ZkSync_SpokePool(
            _wrappedNativeTokenAddress,
            _circleUSDC,
            _zkUSDCBridge,
            _l1ChainId,
            _cctpTokenMessenger,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _gateway
        )
    {}
}
