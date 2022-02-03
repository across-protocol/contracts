// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@eth-optimism/contracts/libraries/bridge/CrossDomainEnabled.sol";
import "@eth-optimism/contracts/L1/messaging/IL1ERC20Bridge.sol";
import "./AdapterInterface.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Sends cross chain messages Optimism L2 network.
 * @dev This contract's owner should be set to the BridgeAdmin deployed on the same L1 network so that only the
 * BridgeAdmin can call cross-chain administrative functions on the L2 DepositBox via this messenger.
 */
contract Optimism_Messenger is Ownable, CrossDomainEnabled, AdapterInterface {
    uint32 public gasLimit;

    address l1Weth;

    IL1ERC20Bridge l1ERC20Bridge;

    constructor(
        uint32 _gasLimit,
        address _crossDomainMessenger,
        address _IL1ERC20Bridge
    ) CrossDomainEnabled(_crossDomainMessenger) {
        gasLimit = _gasLimit;
        l1ERC20Bridge = IL1ERC20Bridge(_IL1ERC20Bridge);
    }

    function relayMessage(address target, bytes memory message) external payable override onlyOwner {
        sendCrossDomainMessage(target, uint32(gasLimit), message);
    }

    function relayTokens(
        address l1Token,
        address l2Token,
        uint256 amount,
        address to
    ) external payable override onlyOwner {
        l1ERC20Bridge.depositERC20To(l1Token, l2Token, to, amount, gasLimit, "0x");
    }
}
