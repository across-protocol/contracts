// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Base_Adapter.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Mode. Contract is a clone of Base_Adapter.sol.
 * @dev Public functions calling external contracts do not guard against reentrancy because they are expected to be
 * called via delegatecall, which will execute this contract's logic within the context of the originating contract.
 * For example, the HubPool will delegatecall these functions, therefore its only necessary that the HubPool's methods
 * that call this contract's logic guard against reentrancy.
 */

// solhint-disable-next-line contract-name-camelcase
contract Mode_Adapter is Base_Adapter {
    /**
     * @notice Constructs new Adapter.
     * @param _l1Weth WETH address on L1.
     * @param _crossDomainMessenger XDomainMessenger Mode system contract.
     * @param _l1StandardBridge Standard bridge contract.
     * @param _l1Usdc USDC address on L1.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) Base_Adapter(_l1Weth, _crossDomainMessenger, _l1StandardBridge, _l1Usdc, _cctpTokenMessenger) {}
}
