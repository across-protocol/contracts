// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/AdapterInterface.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// SNX Bridge does not implement the standard `withdrawTo` required for a Optimism gateway.
interface ISynthetixBridgeToBase {
    function withdrawTo(address to, uint256 amount) external;
}

// solhint-disable-next-line contract-name-camelcase
contract SnxOptimismBridgeWrapper {
    using SafeERC20 for IERC20;

    // Adress obtained from https://docs.synthetix.io/addresses on 05/28/2022.
    // https://optimistic.etherscan.io/address/0x136b1EC699c62b0606854056f02dC7Bb80482d63
    address public immutable snxOptimismBridge = 0x136b1EC699c62b0606854056f02dC7Bb80482d63;

    /**
     * @dev initiate a withdraw of some token to a recipient's account on L1.
     * @param _l2Token Address of L2 token where withdrawal is initiated.
     * @param _to L1 adress to credit the withdrawal to.
     * @param _amount Amount of the token to withdraw.
     * param _l1Gas Unused, but included for potential forward compatibility considerations.
     */
    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32, /* _l1Gas */
        bytes calldata /* _data */
    ) external {
        // Caller should have already pre-approved this contract to pull SNX tokens.
        IERC20(_l2Token).safeTransferFrom(msg.sender, address(this), _amount);
        ISynthetixBridgeToBase(snxOptimismBridge).withdrawTo(_to, _amount);
    }
}
