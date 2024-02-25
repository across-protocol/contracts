// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./SpokePool.sol";
import "./external/interfaces/WETH9Interface.sol";
import "./libraries/CircleCCTPAdapter.sol";

import "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";

// https://github.com/Synthetixio/synthetix/blob/5ca27785fad8237fb0710eac01421cafbbd69647/contracts/SynthetixBridgeToBase.sol#L50
interface SynthetixBridgeToBase {
    function withdrawTo(address to, uint256 amount) external;
}

// https://github.com/ethereum-optimism/optimism/blob/bf51c4935261634120f31827c3910aa631f6bf9c/packages/contracts-bedrock/contracts/L2/L2StandardBridge.sol
interface IL2ERC20Bridge {
    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable;
}

/**
 * @notice OVM specific SpokePool. Uses OVM cross-domain-enabled logic to implement admin only access to functions. * Optimism, Base, and Boba each implement this spoke pool and set their chain specific contract addresses for l2Eth and l2Weth.
 */
contract Ovm_SpokePool is SpokePool, CircleCCTPAdapter {
    // "l1Gas" parameter used in call to bridge tokens from this contract back to L1 via IL2ERC20Bridge. Currently
    // unused by bridge but included for future compatibility.
    uint32 public l1Gas;

    // ETH is an ERC20 on OVM.
    address public l2Eth;

    // Address of the Optimism L2 messenger.
    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;
    // @dev This storage slot is reserved to replace the old messenger public variable that has now been
    // replaced by the above constant.
    address private __deprecated_messenger = address(0);

    // Address of custom bridge used to bridge Synthetix-related assets like SNX.
    address private constant SYNTHETIX_BRIDGE = 0x136b1EC699c62b0606854056f02dC7Bb80482d63;

    // Address of SNX ERC20
    address private constant SNX = 0x8700dAec35aF8Ff88c16BdF0418774CB3D7599B4;

    // Stores alternative token bridges to use for L2 tokens that don't go over the standard bridge. This is needed
    // to support non-standard ERC20 tokens on Optimism, such as DIA and SNX which both use custom bridges.
    mapping(address => address) public tokenBridges;

    event SetL1Gas(uint32 indexed newL1Gas);
    event SetL2TokenBridge(address indexed l2Token, address indexed tokenBridge);

    error NotCrossDomainAdmin();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer,
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger
    )
        SpokePool(_wrappedNativeTokenAddress, _depositQuoteTimeBuffer, _fillDeadlineBuffer)
        CircleCCTPAdapter(_l2Usdc, _cctpTokenMessenger, CircleDomainIds.Ethereum)
    {} // solhint-disable-line no-empty-blocks

    /**
     * @notice Construct the OVM SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _l2Eth Address of L2 ETH token. Usually should be Lib_PreeployAddresses.OVM_ETH but sometimes this can
     * be different, like with Boba which flips the WETH and OVM_ETH addresses.
     */
    function __OvmSpokePool_init(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        address _l2Eth
    ) public onlyInitializing {
        l1Gas = 5_000_000;
        __SpokePool_init(_initialDepositId, _crossDomainAdmin, _hubPool);
        //slither-disable-next-line missing-zero-check
        l2Eth = _l2Eth;
    }

    /*******************************************
     *    OPTIMISM-SPECIFIC ADMIN FUNCTIONS    *
     *******************************************/

    /**
     * @notice Change L1 gas limit. Callable only by admin.
     * @param newl1Gas New L1 gas limit to set.
     */
    function setL1GasLimit(uint32 newl1Gas) public onlyAdmin nonReentrant {
        l1Gas = newl1Gas;
        emit SetL1Gas(newl1Gas);
    }

    /**
     * @notice Set bridge contract for L2 token used to withdraw back to L1.
     * @dev If this mapping isn't set for an L2 token, then the standard bridge will be used to bridge this token.
     * @param tokenBridge Address of token bridge
     */
    function setTokenBridge(address l2Token, address tokenBridge) public onlyAdmin nonReentrant {
        tokenBridges[l2Token] = tokenBridge;
        emit SetL2TokenBridge(l2Token, tokenBridge);
    }

    /**************************************
     *        INTERNAL FUNCTIONS          *
     **************************************/

    /**
     * @notice Wraps any ETH into WETH before executing leaves. This is necessary because SpokePool receives
     * ETH over the canonical token bridge instead of WETH.
     */
    function _preExecuteLeafHook(address l2TokenAddress) internal override {
        if (l2TokenAddress == address(wrappedNativeToken)) _depositEthToWeth();
    }

    // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is necessary because
    // this SpokePool will receive ETH from the canonical token bridge instead of WETH. Its not sufficient to execute
    // this logic inside a fallback method that executes when this contract receives ETH because ETH is an ERC20
    // on the OVM.
    function _depositEthToWeth() internal {
        //slither-disable-next-line arbitrary-send-eth
        if (address(this).balance > 0) wrappedNativeToken.deposit{ value: address(this).balance }();
    }

    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal override {
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
        // If the token is USDC && CCTP bridge is enabled, then bridge USDC via CCTP.
        else if (_isCCTPEnabled() && l2TokenAddress == address(usdcToken)) {
            _transferUsdc(hubPool, amountToReturn);
        }
        // Handle custom SNX bridge which doesn't conform to the standard bridge interface.
        else if (l2TokenAddress == SNX)
            SynthetixBridgeToBase(SYNTHETIX_BRIDGE).withdrawTo(
                hubPool, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn // _amount.
            );
        else
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

    // Apply OVM-specific transformation to cross domain admin address on L1.
    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure its always at the end of storage.
    uint256[1000] private __gap;
}
