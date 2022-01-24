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

    // Timestamp when contract was constructed. Relays cannot have a quote time before this.
    uint64 public deploymentTime;

    // Track the total number of deposits. Used as a unique identifier for deposits.
    uint256 public numberOfDeposits;

    struct DestinationToken {
        address token;
        address spokePool;
        address wethContract;
        bool depositsEnabled;
    }

    // Whitelist of origin token to destination token routings.
    mapping(address => mapping(uint256 => DestinationToken)) public whitelistedDestinationRoutes;


    /****************************************
     *                EVENTS                *
     ****************************************/
    event WhitelistRoute(address originToken, uint256 destinationChainId, address destinationToken, address spokePool, address wethContract);
    event DepositsEnabled(address originToken, uint256 destinationChainId, bool depositsEnabled);
    event FundsDeposited(
        uint256 nonce,
        address originToken,
        uint256 destinationChainId,
        address recipient,
        address sender,
        address destinationToken,
        uint256 amount,
        uint64 relayerFeePct,
        uint64 quoteTimestamp
    );

    constructor(
        address timerAddress
    ) Testable(timerAddress) {
        deploymentTime = uint64(getCurrentTime());
    }

    /****************************************
     *               MODIFIERS              *
     ****************************************/

    modifier onlyIfDepositsEnabled(address originToken, uint256 destinationId) {
        require(whitelistedDestinationRoutes[originToken][destinationId].depositsEnabled, "Deposits disabled");
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    /**
     * @notice Whitelist an origin token <-> destination token route.
     */
    function _whitelistRoute(
        address originToken,
        address destinationToken,
        address spokePool,
        address wethContract,
        uint256 destinationChainId
    ) internal {
        whitelistedDestinationRoutes[originToken][destinationChainId] = DestinationToken({
            token: destinationToken,
            spokePool: spokePool, // Depositing to a destination chain where spoke pool is the 0 address will fail,
            // so admin can set `spokePool` to 0 address to block deposits.
            wethContract: wethContract,
            depositsEnabled: true
        });

        emit WhitelistRoute(originToken, destinationChainId, destinationToken, spokePool, wethContract);
    }

    /**
     * @notice Enable/disable deposits for a whitelisted origin token.
     */
    function _setEnableDeposits(address originToken, uint256 destinationChainId, bool depositsEnabled) internal {
        whitelistedDestinationRoutes[originToken][destinationChainId].depositsEnabled = depositsEnabled;
        emit DepositsEnabled(originToken, destinationChainId, depositsEnabled);
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
        uint256 destinationChainId,
        uint256 amount,
        address recipient,
        uint64 relayerFeePct,
        uint64 quoteTimestamp
    ) public onlyIfDepositsEnabled(originToken, destinationChainId) {
        require(isWhitelistedRoute(originToken, destinationChainId), "deposit token not whitelisted");
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
            originToken,
            destinationChainId,
            recipient,
            msg.sender,
            whitelistedDestinationRoutes[originToken][destinationChainId].token,
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
     * @notice Checks if a given origin to destination route is whitelisted.
     */
    function isWhitelistedRoute(address originToken, uint256 destinationChainId) public view returns (bool) {
        return whitelistedDestinationRoutes[originToken][destinationChainId] != address(0);
    }

    function chainId() public view returns (uint256) {
        return chainId();
    }
}
