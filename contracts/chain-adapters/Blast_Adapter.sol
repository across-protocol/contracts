// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "../external/interfaces/WETH9Interface.sol";
import "./Base_Adapter.sol";
import "@eth-optimism/contracts/L1/messaging/IL1StandardBridge.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Contract containing logic to send messages from L1 to Blast. This is a modified version of the Optimism adapter
 * that excludes the custom bridging logic. It is identical to the Base_Adapter
 */

// solhint-disable-next-line contract-name-camelcase
contract Blast_Adapter is Base_Adapter {
    constructor(
        WETH9Interface _l1Weth,
        address _crossDomainMessenger,
        IL1StandardBridge _l1StandardBridge,
        IERC20 _l1Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) Base_Adapter(_l1Weth, _crossDomainMessenger, _l1StandardBridge, _l1Usdc, _cctpTokenMessenger) {}
}
