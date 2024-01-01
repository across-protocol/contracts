// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/CCTPInterfaces.sol";

library CircleCCTPLib {
    using SafeERC20 for IERC20;

    /**
     * @notice converts address to bytes32 (alignment preserving cast.)
     * @param addr the address to convert to bytes32
     * @dev Sourced from the official CCTP repo: https://github.com/walkerq/evm-cctp-contracts/blob/139d8d0ce3b5531d3c7ec284f89d946dfb720016/src/messages/Message.sol#L142C1-L148C6
     */
    function _addressToBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /**
     * @notice Transfers USDC from the current domain to the given address on the new domain.
     * @param usdcToken USDC token contract on the current domain.
     * @param tokenMessenger TokenMessenger contract to bridge via CCTP.
     * @param circleDomain The new domain to transfer USDC to.
     * @param to Address to receive USDC on the new domain.
     * @param amount Amount of USDC to transfer.
     */
    function _transferUsdc(
        IERC20 usdcToken,
        ITokenMessenger tokenMessenger,
        uint32 circleDomain,
        address to,
        uint256 amount
    ) internal {
        // Only approve the exact amount to be transferred
        usdcToken.safeIncreaseAllowance(address(tokenMessenger), amount);
        // Submit the amount to be transferred to bridged via the TokenMessenger
        tokenMessenger.depositForBurn(amount, circleDomain, _addressToBytes32(to), address(usdcToken));
    }
}
