// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./ZkSync_SpokePool.sol";

/**
 * @notice Lens specific SpokePool. Wrapper around the ZkSync_SpokePool contract.
 * @dev Resources for compiling and deploying contracts with hardhat: https://era.zksync.io/docs/tools/hardhat/hardhat-zksync-solc.html
 * @custom:security-contact bugs@across.to
 */
contract Lens_SpokePool is ZkSync_SpokePool {
    address public immutable usdcAddress;
    ZkBridgeLike public immutable zkUSDCBridge;

    constructor(
        address _wrappedNativeTokenAddress,
        address _l2USDCAddress,
        ZkBridgeLike _zkUSDCBridge,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) ZkSync_SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {
        usdcAddress = _l2USDCAddress;
        zkUSDCBridge = _zkUSDCBridge;
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        if (l2TokenAddress == usdcAddress) {
            zkUSDCBridge.withdraw(withdrawalRecipient, l2TokenAddress, amountToReturn);
        } else {
            super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
        }
    }
}
