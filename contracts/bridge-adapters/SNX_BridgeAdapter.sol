// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@eth-optimism/contracts/L1/messaging/IL1ERC20Bridge.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// SNX Bridge does not implement `depositERC20To`
interface ISNXBridge {
    function depositTo(address to, uint256 amount) external;
}

// Wrapper for the custom Optimism SNX bridge.
contract SNX_BridgeAdapter {
    using SafeERC20 for IERC20;

    address public immutable snx = 0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F;
    address public immutable snxOptimismBridge = 0xCd9D4988C0AE61887B075bA77f08cbFAd2b65068;

    /**
     * @dev deposit an amount of ERC20 to a recipient's balance on L2.
     * @param _to L2 address to credit the withdrawal to.
     * @param _amount Amount of the ERC20 to deposit.
     */
    function depositERC20To(
        address, /* _l1Token */
        address, /* _l2Token */
        address _to,
        uint256 _amount,
        uint32, /* _l2Gas */
        bytes calldata /* _data */
    ) external {
        IERC20 snxToken = IERC20(snx);
        // Caller should have already pre-approved this contract to pull SNX tokens.
        snxToken.safeTransferFrom(msg.sender, address(this), _amount);
        snxToken.safeIncreaseAllowance(address(snxOptimismBridge), _amount);
        ISNXBridge(snxOptimismBridge).depositTo(_to, _amount);
    }
}
