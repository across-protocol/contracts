// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../Ovm_SpokePool.sol";

// Provides payable withdrawTo interface introduced on Bedrock
contract MockBedrockL2StandardBridge is IL2ERC20Bridge {
    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable {
        // do nothing
    }
}
