// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

import "../Ovm_SpokePool.sol";
import "../external/interfaces/CCTPInterfaces.sol";

/**
 * @notice Mock Blast Spoke pool for testing purposes.
 * @dev This doesn't inherit from Blast_SpokePool to avoid hardcoded constant addresses
 * @custom:security-contact bugs@across.to
 */
contract MockBlast_SpokePool is Ovm_SpokePool {
    // Store addresses that are immutable in the real contract as regular state variables here
    address public usdb;
    address public l1Usdb;
    address public yieldRecipient;
    address public blastRetriever;

    // fee cap to use for XERC20 transfers through Hyperlane. 1 ether is default for ETH gas token chains
    uint256 private constant HYP_XERC20_FEE_CAP = 1 ether;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        address _usdb,
        address _l1Usdb,
        address _yieldRecipient,
        address _blastRetriever
    )
        Ovm_SpokePool(
            _wrappedNativeTokenAddress,
            _depositQuoteTimeBuffer,
            _fillDeadlineBuffer,
            _l2Usdc,
            _cctpTokenMessenger,
            HYP_XERC20_FEE_CAP
        )
    {
        // Store these as regular state variables instead of immutable
        usdb = _usdb;
        l1Usdb = _l1Usdb;
        yieldRecipient = _yieldRecipient;
        blastRetriever = _blastRetriever;
    }

    /**
     * @notice Simplified initialize function that skips calls to Blast-specific contracts
     */
    function initialize(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public initializer {
        // Only call the OvmSpokePool initialization, skip the Blast-specific calls
        __OvmSpokePool_init(_initialDepositId, _crossDomainAdmin, _withdrawalRecipient, Lib_PredeployAddresses.OVM_ETH);

        // No need to call the problematic functions:
        // BLAST_YIELD_CONTRACT.configureClaimableYield();
        // BLAST_YIELD_CONTRACT.configureClaimableGas();
        // IERC20Rebasing(USDB).configure(IERC20Rebasing.YieldMode.CLAIMABLE);
        // IERC20Rebasing(address(wrappedNativeToken)).configure(IERC20Rebasing.YieldMode.CLAIMABLE);
    }

    /**
     * @notice Simplified implementation that skips Blast-specific behavior
     */
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
        // Simply call the parent SpokePool implementation without any Blast-specific logic
        super._bridgeTokensToHubPool(amountToReturn, l2TokenAddress);
    }
}
