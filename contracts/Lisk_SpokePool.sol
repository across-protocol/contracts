// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./external/interfaces/CCTPInterfaces.sol";
import { IOpUSDCBridgeAdapter } from "./external/interfaces/IOpUSDCBridgeAdapter.sol";

/**
 * @notice Lisk SpokePool.
 * @custom:security-contact bugs@across.to
 */
contract Lisk_SpokePool is Ovm_SpokePool {
    using SafeERC20 for IERC20;

    // Address of the custom L2 USDC bridge.
    address public constant USDC_BRIDGE = 0x3b1ac69368eb6447F5db2d4E1641380Fa9e40d29;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        Ovm_SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger
        )
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct an OVM-derived SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient, Lib_PredeployAddresses.OVM_ETH);
    }

    /**
     * @notice Chain-specific logic to bridge tokens back to the hub pool contract on L1.
     * @param amountToReturn Amount of the token to bridge back.
     * @param l2TokenAddress Address of the l2 Token to bridge back. This token will either be bridged back to the token defined in the mapping `remoteL1Tokens`,
     * or via the canonical mapping defined in the bridge contract retrieved from `tokenBridges`.
     * @dev This implementation deviates slightly from `_bridgeTokensToHubPool` in the `Ovm_SpokePool` contract since this chain has a USDC bridge which uses
     * a custom interface. This is because the USDC token on this chain is meant to be upgraded to a native, CCTP supported version in the future.
     */
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        // Handle custom USDC bridge which doesn't conform to the standard bridge interface. In the future, CCTP may be used to bridge USDC to mainnet, in which
        // case bridging logic is handled by the Ovm_SpokePool code. In the meantime, if CCTP is not enabled, then use the USDC bridge. Once CCTP is activated on
        // Lisk, this block of code will be unused.
        if (l2TokenAddress == address(usdcToken) && !_isCCTPEnabled()) {
            usdcToken.safeIncreaseAllowance(USDC_BRIDGE, amountToReturn);
            IOpUSDCBridgeAdapter(USDC_BRIDGE).sendMessage(
                withdrawalRecipient, // _to. Withdraw, over the bridge, to the l1 hub pool contract.
                amountToReturn, // _amount.
                l1Gas // _minGasLimit. Same value used in other OpStack bridges.
            );
        } else super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}
