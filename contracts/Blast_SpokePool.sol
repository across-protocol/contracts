// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "./Ovm_SpokePool.sol";
import "./external/interfaces/CCTPInterfaces.sol";

// USDB and WETH on Blast accrue yield that can be claimed by any account holding the token. So for the length of
// time that the SpokePool holds on to these assets, it can can claim interest.
interface IERC20Rebasing {
    enum YieldMode {
        AUTOMATIC,
        VOID,
        CLAIMABLE
    }

    function claim(address recipient, uint256 amount) external returns (uint256);

    function getClaimableAmount(address account) external view returns (uint256);

    function configure(YieldMode yieldMode) external returns (uint256);
}

// Interface for blast yield contract on L2.
interface IBlast {
    function configureClaimableYield() external;

    function claimAllYield(address contractAddress, address recipientOfYield) external returns (uint256);

    function configureClaimableGas() external;

    function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
}

/**
 * @notice Blast Spoke pool.
 */
contract Blast_SpokePool is Ovm_SpokePool {
    // This is the yield-accruing stablecoin on Blast that USDC/DAI/USDT all bridge into. It can be withdrawn
    // from L2 into DAI.
    address public immutable USDB; // 0x4300000000000000000000000000000000000003 on blast mainnet.
    // Token that is received when withdrawing USDB, aka DAI.
    address public immutable L1_USDB; // 0x6B175474E89094C44Da98b954EedeAC495271d0F on mainnet.

    // Address that this contract's yield and gas fees accrue to.
    address public immutable YIELD_RECIPIENT;
    address public constant L2_BLAST_BRIDGE = 0x4300000000000000000000000000000000000005;
    IBlast public constant BLAST_YIELD_CONTRACT = IBlast(0x4300000000000000000000000000000000000002);

    error InvalidClaimedAmount(address token);
    event YieldClaimed(address indexed recipient, address indexed token, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        address usdb,
        address l1Usdb,
        address yieldRecipient
    )
        Ovm_SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger
        )
    {
        USDB = usdb;
        L1_USDB = l1Usdb;
        YIELD_RECIPIENT = yieldRecipient;
    }

    /**
     * @notice Construct the OVM Blast SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @dev this method also sets yield settings for the Blast SpokePool.
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public initializer {
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool, Lib_PredeployAddresses.OVM_ETH);

        // Sets native yield to be claimable manually.
        BLAST_YIELD_CONTRACT.configureClaimableYield();
        BLAST_YIELD_CONTRACT.configureClaimableGas();

        // Set USDB and WETH to claimable.
        IERC20Rebasing(USDB).configure(IERC20Rebasing.YieldMode.CLAIMABLE);
        IERC20Rebasing(address(wrappedNativeToken)).configure(IERC20Rebasing.YieldMode.CLAIMABLE);
    }

    /**
     * @notice Claim interest for token to a predefined recipient. This should be called before _bridgeTokensToHubPool
     * as a way to regularly claim yield and distribute it to the recipient.
     */
    function _claimYield(IERC20Rebasing token) internal {
        uint256 claimableAmount = token.getClaimableAmount(address(this));
        uint256 claimedAmount = token.claim(YIELD_RECIPIENT, claimableAmount);
        if (claimableAmount != claimedAmount) {
            revert InvalidClaimedAmount(address(token));
        }

        if (claimedAmount > 0) {
            emit YieldClaimed(YIELD_RECIPIENT, address(token), claimedAmount);
        }

        // If sending WETH back, also claim any native yield and convert it to WETH.
        if (address(token) == address(wrappedNativeToken)) {
            uint256 nativeClaimAmount = BLAST_YIELD_CONTRACT.claimAllYield(address(this), YIELD_RECIPIENT);
            nativeClaimAmount += BLAST_YIELD_CONTRACT.claimMaxGas(address(this), YIELD_RECIPIENT);
            if (nativeClaimAmount > 0) {
                emit YieldClaimed(YIELD_RECIPIENT, address(0), nativeClaimAmount);
            }
        }
    }

    // Claims any yield for tokens that accrue yield before bridging.
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        if (l2TokenAddress == USDB || l2TokenAddress == address(wrappedNativeToken)) {
            _claimYield(IERC20Rebasing(l2TokenAddress));
        }
        // If the token is USDB then use the L2BlastBridge
        if (l2TokenAddress == USDB) {
            IL2ERC20Bridge(L2_BLAST_BRIDGE).bridgeERC20To(
                l2TokenAddress, // _l2Token. Address of the L2 token to bridge over.
                L1_USDB,
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn,
                l1Gas,
                ""
            );
        } else super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}
