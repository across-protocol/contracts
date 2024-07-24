// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./external/interfaces/CCTPInterfaces.sol";

// https://github.com/Synthetixio/synthetix/blob/5ca27785fad8237fb0710eac01421cafbbd69647/contracts/SynthetixBridgeToBase.sol#L50
interface SynthetixBridgeToBase {
    function withdrawTo(address to, uint256 amount) external;
}

/**
 * @notice Optimism Spoke pool.
 */
contract Optimism_SpokePool is Ovm_SpokePool {
    // Address of custom bridge used to bridge Synthetix-related assets like SNX.
    address private constant SYNTHETIX_BRIDGE = 0x136b1EC699c62b0606854056f02dC7Bb80482d63;

    // Address of SNX ERC20
    address private constant SNX = 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4;

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
     * @notice Construct the OVM Optimism SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, Lib_PredeployAddresses.OVM_ETH);
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual override {
        // Handle custom SNX bridge which doesn't conform to the standard bridge interface.
        if (l2TokenAddress == SNX)
            SynthetixBridgeToBase(SYNTHETIX_BRIDGE).withdrawTo(
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn // _amount.
            );
        else super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}
