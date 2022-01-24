//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";

/**
 * @title SpokePool
 * @notice Contract deployed on source and destination chains enabling depositors to transfer assets from source to 
 * destination. Deposit orders are fulfilled by off-chain relayers who also interact with this contract. Deposited
 * tokens are locked on the source chain and relayers send the recipient the desired token currency and amount
 * on the destination chain. Locked source chain tokens are later sent over the canonical token bridge to L1.
 */
contract SpokePool is Testable, Lockable, MultiCaller {
    using SafeERC20 for IERC20;

    // Chain ID for this contract.
    uint256 public chainId;

    // Timestamp when contract was constructed. Relays cannot have a quote time before this.
    uint64 public deploymentTime;

    // Track the total number of deposits. Used as a unique identifier for relays.
    uint256 public numberOfDeposits;

    // // Address of WETH on L1. If the deposited token maps to this L1 token then wrap ETH to WETH on the users behalf.
    // address public l1Weth;

    struct DestinationToken {
        address token;
        address spokePool;
        uint256 chainId;
        bool depositsEnabled;
    }

    // Whitelist of origin token to destination token mappings.
    mapping(address => DestinationToken) public whitelistedDestinationTokens;


    /****************************************
     *                EVENTS                *
     ****************************************/
    event WhitelistToken(address originToken, address destinationToken, uint256 destinationChainId, address spokePool);
    event DepositsEnabled(address originToken, bool depositsEnabled);
    event FundsDeposited(
        uint256 nonce,
        uint256 destinationChainId,
        address recipient,
        address sender,
        address originToken,
        address destinationToken,
        uint256 amount,
        uint64 relayerFeePct,
        uint64 quoteTimestamp
    );

    constructor(
        uint256 _chainId,
        // address _l1Weth,
        address timerAddress
    ) Testable(timerAddress) {
        deploymentTime = uint64(getCurrentTime());
        chainId = _chainId; 
    }

    /****************************************
     *               MODIFIERS              *
     ****************************************/

    modifier onlyIfDepositsEnabled(address originToken) {
        require(whitelistedDestinationTokens[originToken].depositsEnabled, "Deposits disabled");
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    /**
     * @notice Whitelist an origin token <-> destination oken pair for bridging.
     */
    function _whitelistToken(
        address originToken,
        address destinationToken,
        address spokePool,
        uint256 destinationChainId
    ) internal {
        require(destinationChainId != 0, "Invalid chain ID"); // 0 is reserved ID to signal non-whitelisted tokens.
        whitelistedDestinationTokens[originToken] = DestinationToken({
            token: destinationToken,
            spokePool: spokePool,
            chainId: destinationChainId,
            depositsEnabled: true
        });

        emit WhitelistToken(originToken, destinationToken, destinationChainId, spokePool);
    }

    /**
     * @notice Enable/disable deposits for a whitelisted origin token.
     */
    function _setEnableDeposits(address originToken, bool depositsEnabled) internal {
        whitelistedDestinationTokens[originToken].depositsEnabled = depositsEnabled;
        emit DepositsEnabled(originToken, depositsEnabled);
    }

    /**************************************
     *         DEPOSITOR FUNCTIONS        *
     **************************************/

    /**
     * @notice Called by user to bridge funds from origin to destination chain.
     * @dev The caller must first approve this contract to spend `amount` of `originToken`.
     */
    function deposit(
        address originToken,
        uint256 amount,
        address recipient,
        uint256 destinationChainId,
        uint256 relayerFeePct,
        uint64 quoteTimestamp
    ) public onlyIfDepositsEnabled(originToken) {
        require(isWhitelistToken(originToken), "deposit token not whitelisted");
        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(relayerFeePct <= 0.5e18, "invalid relayer fee");
        // Note We assume that L2 timing cannot be compared accurately and consistently to L1 timing. Therefore, 
        // `block.timestamp` is different from the L1 EVM's. Therefore, the quoteTimestamp must be within 10
        // mins of the current time to allow for this variance.
        // Note also that `quoteTimestamp` cannot be less than 10 minutes otherwise the following arithmetic can result
        // in underflow. This isn't a problem as the deposit will revert, but the error might be unexpected for clients.
        // Consider requiring `quoteTimestamp >= 10 minutes`.
        require(
            getCurrentTime() >= quoteTimestamp - 10 minutes && 
            getCurrentTime() <= quoteTimestamp + 10 minutes &&
            quoteTimestamp >= deploymentTime,
            "invalid quote time"
        );
        // // If the address of the L1 token is the l1Weth and there is a msg.value with the transaction then the user
        // // is sending ETH. In this case, the ETH should be deposited to WETH.
        // if (whitelistedDestinationTokens[originToken].token == l1Weth && msg.value > 0) {
        //     require(msg.value == amount, "msg.value must match amount");
        //     WETH9Like(address(originToken)).deposit{ value: msg.value }();
        // }

        // Else, it is a normal ERC20. In this case pull the token from the users wallet as per normal.
        // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them. In
        // this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        IERC20(originToken).safeTransferFrom(msg.sender, address(this), amount);

        emit FundsDeposited(
            numberOfDeposits, // The total number of deposits for this contract acts as a unique ID.
            whitelistedDestinationTokens[originToken].chainId,
            recipient,
            msg.sender,
            originToken,
            whitelistedDestinationTokens[originToken].token,
            amount,
            relayerFeePct,
            quoteTimestamp
        );

        numberOfDeposits += 1;
    }

    function initiateRelay(
        uint256 originChain,
        address sender,
        uint256 amount,
        address recipient,
        uint256 relayerFee,
        uint256 realizedLpFee
    ) public {}

    function fillRelay(
        uint256 relayId,
        uint256 fillAmount,
        uint256 repaymentChain
    ) public {}

    function initializeRelayerRefund(bytes32 relayerRepaymentDistributionProof) public {}

    function distributeRelayerRefund(
        uint256 relayerRefundId,
        uint256 leafId,
        address l2TokenAddress,
        uint256 netSendAmount,
        address[] memory relayerRefundAddresses,
        uint256[] memory relayerRefundAmounts,
        bytes32[] memory inclusionProof
    ) public {}

    /**************************************
     *           VIEW FUNCTIONS           *
     **************************************/

    /**
     * @notice Checks if a given origin token is whitelisted.
     */
    function isWhitelistToken(address originToken) public view returns (bool) {
        return whitelistedDestinationTokens[originToken].chainId != 0;
    }
}
