// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";

contract Scroll_SpokePool is SpokePool {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /******************************************
     *          PUBLIC FUNCTIONS              *
     ******************************************/

    /**************************************
     *         ITERNAL FUNCTIONS          *
     **************************************/

    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        amountToReturn;
        l2TokenAddress;
    }

    function _requireAdminSender() internal override {} // solhint-disable-line no-empty-blocks
}
