// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./libraries/CCTPAdapter.sol";

/**
 * @notice Optimism Spoke pool.
 */
contract Optimism_SpokePool is Ovm_SpokePool {
    /**
     * @notice Domain identifier used for Circle's CCTP bridge to L1.
     * @dev This identifier is assigned by Circle and is not related to a chain ID.
     * @dev Official domain list can be found here: https://developers.circle.com/stablecoins/docs/supported-domains
     */
    uint32 public constant l1CircleDomainId = 0;
    /**
     * @notice The official USDC contract address on this chain.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/usdc-on-main-networks
     */
    IERC20 public l2Usdc;
    /**
     * @notice The official Circle CCTP token bridge contract endpoint.
     * @dev Posted officially here: https://developers.circle.com/stablecoins/docs/evm-smart-contracts
     */
    ITokenMessenger public cctpTokenMessenger;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) Ovm_SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer) {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the OVM Optimism SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _l2Usdc USDC address on this L2 chain.
     * @param _cctpTokenMessenger TokenMessenger contract to bridge via CCTP.
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, Lib_PredeployAddresses.OVM_ETH);
        l2Usdc = _l2Usdc;
        cctpTokenMessenger = _cctpTokenMessenger;
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // We override this instead of implementing directly in the ovm spoke pool because not all
        // OVM spoke pools will need to bridge tokens via CCTP. For example, the Boba spoke pool
        // bridges tokens via the standard OVM logic.
        if (l2TokenAddress == address(l2Usdc)) {
            CircleCCTPLib._transferUsdc(l2Usdc, cctpTokenMessenger, l1CircleDomainId, hubPool, amountToReturn);
            emit OptimismTokensBridged(l2TokenAddress, hubPool, amountToReturn, l1Gas);
        } else {
            // Call the super implementation to bridge the token
            super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
        }
    }
}
