// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../external/interfaces/CCTPInterfaces.sol";

abstract contract CCTPAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable l1Usdc;
    uint32 public immutable circleDomain;
    ITokenMessenger public immutable tokenMessenger;

    constructor(
        IERC20 _l1Usdc,
        uint32 _circleDomain,
        ITokenMessenger _tokenMessenger
    ) {
        l1Usdc = _l1Usdc;
        circleDomain = _circleDomain;
        tokenMessenger = _tokenMessenger;
    }

    function _isL1Usdc(address l1Token) internal view returns (bool) {
        return l1Token == address(l1Usdc);
    }

    function _transferFromL1Usdc(address to, uint256 amount) internal {
        // Only approve the exact amount to be transferred
        l1Usdc.safeIncreaseAllowance(address(tokenMessenger), amount);
        // Submit the amount to be transferred to bridged via the TokenMessenger
        tokenMessenger.depositForBurn(amount, circleDomain, _addressToBytes32(to), address(l1Usdc));
    }

    /**
     * @notice converts address to bytes32 (alignment preserving cast.)
     * @param addr the address to convert to bytes32
     * @dev Sourced from the official CCTP repo: https://github.com/walkerq/evm-cctp-contracts/blob/139d8d0ce3b5531d3c7ec284f89d946dfb720016/src/messages/Message.sol#L142C1-L148C6
     */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
