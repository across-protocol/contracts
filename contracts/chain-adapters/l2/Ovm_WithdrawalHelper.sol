// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.19;

import { WithdrawalHelperBase } from "./WithdrawalHelperBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { WETH9Interface } from "../../external/interfaces/WETH9Interface.sol";
import { ITokenMessenger } from "../../external/interfaces/CCTPInterfaces.sol";
import { Lib_PredeployAddresses } from "@eth-optimism/contracts/libraries/constants/Lib_PredeployAddresses.sol";
import { LibOptimismUpgradeable } from "@openzeppelin/contracts-upgradeable/crosschain/optimism/LibOptimismUpgradeable.sol";
import { IL2ERC20Bridge } from "../../Ovm_SpokePool.sol";

/**
 * @notice Minimal interface for the Ovm_SpokePool contract. This interface is called to pull state from the network's
 * spoke pool contract to be used by this withdrawal adapter.
 */
interface IOvm_SpokePool {
    // Returns the address of the token bridge for the input l2 token.
    function tokenBridges(address token) external view returns (address);

    // Returns the address of the l1 token set in the spoke pool for the input l2 token.
    function remoteL1Tokens(address token) external view returns (address);

    // Returns the address for the representation of ETH on the l2.
    function l2Eth() external view returns (address);

    // Returns the address of the wrapped native token for the L2.
    function wrappedNativeToken() external view returns (WETH9Interface);

    // Returns the amount of gas the contract allocates for a token withdrawal.
    function l1Gas() external view returns (uint32);
}

/**
 * @title Ovm_WithdrawalAdapter
 * @notice This contract interfaces with L2-L1 token bridges and withdraws tokens to a single address on L1.
 * @dev This contract should be deployed on OpStack L2s which both have a Ovm_SpokePool contract deployed to the L2
 * network AND only use token bridges defined in the Ovm_SpokePool. A notable exception to this requirement is Optimism,
 * which has a special SNX bridge (and thus this adapter will NOT work for Optimism).
 * @custom:security-contact bugs@across.to
 */
contract Ovm_WithdrawalHelper is WithdrawalHelperBase {
    using SafeERC20 for IERC20;

    // Address for the wrapped native token on this chain. For Ovm standard bridges, we need to unwrap
    // this token before initiating the withdrawal. Normally, it is 0x42..006, but there are instances
    // where this address is different.
    WETH9Interface public immutable wrappedNativeToken;
    // Address of the corresponding spoke pool on L2. This is to piggyback off of the spoke pool's supported
    // token routes/defined token bridges.
    IOvm_SpokePool public immutable spokePool;
    // Address of native ETH on the l2. For OpStack chains, this address is used to indicate a native ETH withdrawal.
    // In general, this address is 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
    address public immutable l2Eth;
    // Address of the messenger contract on L2. This is by default defined in Lib_PredeployAddresses.
    address public constant MESSENGER = Lib_PredeployAddresses.L2_CROSS_DOMAIN_MESSENGER;

    /*
     * @notice Constructs the Ovm_WithdrawalAdapter.
     * @param _l2Usdc Address of native USDC on the L2.
     * @param _cctpTokenMessenger Address of the CCTP token messenger contract on L2.
     * @param _destinationCircleDomainId Circle's assigned CCTP domain ID for the destination network. For Ethereum, this
     * is 0.
     * @param _l2Gateway Address of the Optimism ERC20 L2 standard bridge contract.
     * @param _tokenRecipient The L1 address which will unconditionally receive tokens from withdrawals by this contract.
     * @param _spokePool The contract address of the Ovm_SpokePool which is deployed on this L2 network.
     */
    constructor(
        IERC20 _l2Usdc,
        ITokenMessenger _cctpTokenMessenger,
        uint32 _destinationCircleDomainId,
        address _l2Gateway,
        address _tokenRecipient,
        IOvm_SpokePool _spokePool
    ) WithdrawalHelperBase(_l2Usdc, _cctpTokenMessenger, _destinationCircleDomainId, _l2Gateway, _tokenRecipient) {
        spokePool = _spokePool;

        // These addresses should only change network-by-network, or after a bridge upgrade, so we define them once in the constructor.
        wrappedNativeToken = spokePool.wrappedNativeToken();
        l2Eth = spokePool.l2Eth();
    }

    /**
     * @notice Initializes the withdrawal helper contract.
     * @param _crossDomainAdmin L1 address of the contract which can send root bundles/messages to this forwarder contract.
     */
    function initialize(address _crossDomainAdmin) public initializer {
        __WithdrawalHelper_init(_crossDomainAdmin);
    }

    /*
     * @notice Calls CCTP or the Optimism token gateway to withdraw tokens back to the recipient.
     * @param l2Token address of the l2Token to send back.
     * @param amountToReturn amount of l2Token to send back.
     * @dev The l1Token parameter is unused since we obtain the l1Token to receive by querying the state of the Ovm_SpokePool deployed
     * to this network.
     * @dev This function is a copy of the `_bridgeTokensToHubPool` function found on the Ovm_SpokePool contract here:
     * https://github.com/across-protocol/contracts/blob/65191dbcded95c8fe050e0f95eb7848e3784e61f/contracts/Ovm_SpokePool.sol#L148.
     * New lines of code correspond to instances where this contract queries state from the spoke pool, such as determining
     * the appropriate token bridge for the withdrawal or finding the remoteL1Token to withdraw.
     */
    function withdrawToken(
        address,
        address l2Token,
        uint256 amountToReturn
    ) public override {
        // Fetch the current l1Gas defined in the Ovm_SpokePool.
        uint32 l1Gas = spokePool.l1Gas();
        // If the token being bridged is WETH then we need to first unwrap it to ETH and then send ETH over the
        // canonical bridge. On Optimism, this is address 0xDeadDeAddeAddEAddeadDEaDDEAdDeaDDeAD0000.
        if (l2Token == address(wrappedNativeToken)) {
            WETH9Interface(l2Token).withdraw(amountToReturn); // Unwrap into ETH.
            l2Token = l2Eth; // Set the l2Token to ETH.
            IL2ERC20Bridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo{ value: amountToReturn }(
                l2Token, // _l2Token. Address of the L2 token to bridge over.
                TOKEN_RECIPIENT, // _to. Withdraw, over the bridge, to the l1 pool contract.
                amountToReturn, // _amount.
                l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                "" // _data. We don't need to send any data for the bridging action.
            );
        }
        // If the token is USDC && CCTP bridge is enabled, then bridge USDC via CCTP.
        else if (l2Token == address(usdcToken) && _isCCTPEnabled()) {
            _transferUsdc(TOKEN_RECIPIENT, amountToReturn);
        }
        // Note we'll default to withdrawTo instead of bridgeERC20To unless the remoteL1Tokens mapping is set for
        // the l2Token. withdrawTo should be used to bridge back non-native L2 tokens
        // (i.e. non-native L2 tokens have a canonical L1 token). If we should bridge "native L2" tokens then
        // we'd need to call bridgeERC20To and give allowance to the tokenBridge to spend l2Token from this contract.
        // Therefore for native tokens we should set ensure that remoteL1Tokens is set for the l2Token.
        else {
            IL2ERC20Bridge tokenBridge = IL2ERC20Bridge(
                spokePool.tokenBridges(l2Token) == address(0)
                    ? Lib_PredeployAddresses.L2_STANDARD_BRIDGE
                    : spokePool.tokenBridges(l2Token)
            );
            address remoteL1Token = spokePool.remoteL1Tokens(l2Token);
            if (remoteL1Token != address(0)) {
                // If there is a mapping for this L2 token to an L1 token, then use the L1 token address and
                // call bridgeERC20To.
                IERC20(l2Token).safeIncreaseAllowance(address(tokenBridge), amountToReturn);
                tokenBridge.bridgeERC20To(
                    l2Token, // _l2Token. Address of the L2 token to bridge over.
                    remoteL1Token, // Remote token to be received on L1 side. If the
                    // remoteL1Token on the other chain does not recognize the local token as the correct
                    // pair token, the ERC20 bridge will fail and the tokens will be returned to sender on
                    // this chain.
                    TOKEN_RECIPIENT, // _to
                    amountToReturn, // _amount
                    l1Gas, // _l1Gas
                    "" // _data
                );
            } else {
                tokenBridge.withdrawTo(
                    l2Token, // _l2Token. Address of the L2 token to bridge over.
                    TOKEN_RECIPIENT, // _to. Withdraw, over the bridge, to the l1 pool contract.
                    amountToReturn, // _amount.
                    l1Gas, // _l1Gas. Unused, but included for potential forward compatibility considerations
                    "" // _data. We don't need to send any data for the bridging action.
                );
            }
        }
    }

    function _requireAdminSender() internal view override {
        if (LibOptimismUpgradeable.crossChainSender(MESSENGER) != crossDomainAdmin) revert NotCrossDomainAdmin();
    }
}
