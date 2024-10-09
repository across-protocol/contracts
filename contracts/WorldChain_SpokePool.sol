// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./external/interfaces/CCTPInterfaces.sol";

// https://github.com/defi-wonderland/opUSDC/blob/ef22e5731f1655bf5249b2160452cce9aa06ff3f/src/contracts/L2OpUSDCBridgeAdapter.sol#L150
interface UsdcBridgeInterface {
    function sendMessage(
        address to,
        uint256 amount,
        uint32 minGasLimit
    ) external;
}

/**
 * @notice WorldChain Spoke pool.
 * @custom:security-contact bugs@across.to
 */
contract WorldChain_SpokePool is Ovm_SpokePool {
    using SafeERC20 for IERC20;

    // Address of the custom L2 USDC bridge.
    address private constant USDC_BRIDGE = 0xbD80b06d3dbD0801132c6689429aC09Ca6D27f82;

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
     * @notice Construct the OVM WorldChain SpokePool.
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

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        // Handle custom USDC bridge which doesn't conform to the standard bridge interface. In the future, CCTP may be used to bridge USDC to mainnet, in which
        // case bridging logic is handled by the Ovm_SpokePool code. In the meantime, if CCTP is not enabled, then use the USDC bridge. Once CCTP is activated on
        // WorldChain, this block of code will be unused.
        if (l2TokenAddress == address(usdcToken) && !_isCCTPEnabled()) {
            usdcToken.safeIncreaseAllowance(USDC_BRIDGE, amountToReturn);
            UsdcBridgeInterface(USDC_BRIDGE).sendMessage(
                withdrawalRecipient, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn, // _amount.
                l1Gas // _minGasLimit. Same value used in other OpStack bridges.
            );
        } else super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}
