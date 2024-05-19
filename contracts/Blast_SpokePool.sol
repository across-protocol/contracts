// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./external/interfaces/CCTPInterfaces.sol";

// USDB and WETH on Blast accrue yield that can be claimed by any account holding the token. So for the length of
// time that the SpokePool holds on to these assets, it can can claim interest.
interface IERC20Rebasing {
    function claim(address recipient, uint256 amount) external returns (uint256);

    function getClaimableAmount(address account) external view returns (uint256);
}

/**
 * @notice Blast Spoke pool.
 */
contract Blast_SpokePool is Ovm_SpokePool {
    // This is the yield-accruing stablecoin on Blast that USDC/DAI/USDT all bridge into. It can be withdrawn
    // from L2 into DAI.
    address private constant USDB = 0x4300000000000000000000000000000000000003;
    // Token that is received when withdrawing USDB, aka DAI.
    address private immutable L1_USDB; // 0x6B175474E89094C44Da98b954EedeAC495271d0F on mainnet.
    address private constant L2_BLAST_BRIDGE = 0x4300000000000000000000000000000000000005;

    error InvalidClaimedAmount(address token);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        address l1Usdb
    )
        Ovm_SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger
        )
    {
        L1_USDB = l1Usdb;
    } // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the OVM Blast SpokePool.
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

    /**
     * @notice Claim interest for token into this contract. This should be called before _bridgeTokensToHubPool
     * and then the claimed amount should be added to the bridged amount.
     */
    function _claimYield(IERC20Rebasing token) internal returns (uint256 claimedAmount) {
        uint256 claimableAmount = token.getClaimableAmount(address(this));
        claimedAmount = token.claim(address(this), claimableAmount);
        if (claimableAmount != claimedAmount) {
            revert InvalidClaimedAmount(address(token));
        }
    }

    /**
     * @notice Claims any yield for tokens that accrue yield and then also bridges those
     */
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        if (l2TokenAddress == USDB || l2TokenAddress == address(wrappedNativeToken)) {
            uint256 accruedYield = _claimYield(IERC20Rebasing(l2TokenAddress));
            amountToReturn += accruedYield;
        }
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (l2TokenAddress == address(wrappedNativeToken)) {
            WETH9Interface(l2TokenAddress).withdraw(amountToReturn); // Unwrap into ETH.
            l2TokenAddress = l2Eth; // Set the l2TokenAddress to ETH.
            IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo{ value: amountToReturn }(
                l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn, // _amount.
                l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
        // If the token is USDB then use the L2BlastBridge
        else if (l2TokenAddress == USDB) {
            IL2ERC20Bridge(L2_BLAST_BRIDGE).bridgeERC20To(
                l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                L1_USDB,
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn,
                l1Gas,
                ""
            );
        } else
            IL2ERC20Bridge(
                tokenBridges[l2TokenAddress] == address(0)
                    ? Lib_PredeployAddresses.L2_STANDARD_BRIDGE
                    : tokenBridges[l2TokenAddress]
            ).withdrawTo(
                    l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                    hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                    amountToReturn, // _amount.
                    l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                    "" // _data. We don't need to send any data for the bridging action.
                );
    }
}
