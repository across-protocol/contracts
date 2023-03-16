// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./interfaces/WETH9Interface.sol";
import "./SpokePoolInterface.sol";
import "./upgradeable/MultiCallerUpgradeable.sol";
import "./upgradeable/EIP712CrossChainUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

// This interface is expected to be implemented by any contract that expects to recieve messages from the SpokePool.
interface AcrossMessageHandler {
    function handleAcrossMessage(
        address tokenSent,
        uint256 amount,
        bytes memory message
    ) external;
}

/**
 * @title SpokePool
 * @notice Base contract deployed on source and destination chains enabling depositors to transfer assets from source to
 * destination. Deposit orders are fulfilled by off-chain relayers who also interact with this contract. Deposited
 * tokens are locked on the source chain and relayers send the recipient the desired token currency and amount
 * on the destination chain. Locked source chain tokens are later sent over the canonical token bridge to L1 HubPool.
 * Relayers are refunded with destination tokens out of this contract after another off-chain actor, a "data worker",
 * submits a proof that the relayer correctly submitted a relay on this SpokePool.
 */
abstract contract SpokePool is
    SpokePoolInterface,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    MultiCallerUpgradeable,
    EIP712CrossChainUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;

    // Address of the L1 contract that acts as the owner of this SpokePool. This should normally be set to the HubPool
    // address. The crossDomainAdmin address is unused when the SpokePool is deployed to the same chain as the HubPool.
    address public crossDomainAdmin;

    // Address of the L1 contract that will send tokens to and receive tokens from this contract to fund relayer
    // refunds and slow relays.
    address public hubPool;

    // Address of wrappedNativeToken contract for this network. If an origin token matches this, then the caller can
    // optionally instruct this contract to wrap native tokens when depositing (ie ETH->WETH or MATIC->WMATIC).
    WETH9Interface public wrappedNativeToken;

    // Any deposit quote times greater than or less than this value to the current contract time is blocked. Forces
    // caller to use an approximately "current" realized fee. Defaults to 1 hour.
    uint32 public depositQuoteTimeBuffer;

    // Count of deposits is used to construct a unique deposit identifier for this spoke pool.
    uint32 public numberOfDeposits;

    // Whether deposits and fills are disabled.
    bool public pausedFills;
    bool public pausedDeposits;

    // This contract can store as many root bundles as the HubPool chooses to publish here.
    RootBundle[] public rootBundles;

    // Origin token to destination token routings can be turned on or off, which can enable or disable deposits.
    mapping(address => mapping(uint256 => bool)) public enabledDepositRoutes;

    // Each relay is associated with the hash of parameters that uniquely identify the original deposit and a relay
    // attempt for that deposit. The relay itself is just represented as the amount filled so far. The total amount to
    // relay, the fees, and the agents are all parameters included in the hash key.
    mapping(bytes32 => uint256) public relayFills;

    // This keeps track of the worst-case liabilities due to fills.
    // It is never reset. Users should only rely on it to determine the worst-case increase in liabilities between
    // two points. This is used to provide frontrunning protection to ensure the relayer's assumptions about the state
    // upon which their expected repayments are based will not change before their transaction is mined.
    mapping(address => uint256) public fillCounter;

    // This keeps track of the total running deposits for each token. This allows depositors to protect themselves from
    // frontrunning that might change their worst-case quote.
    mapping(address => uint256) public depositCounter;

    uint256 public constant MAX_TRANSFER_SIZE = 1e36;

    bytes32 public constant UPDATE_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,int64 updatedRelayerFeePct,address updatedRecipient,bytes updatedMessage)"
        );

    /****************************************
     *                EVENTS                *
     ****************************************/
    event SetXDomainAdmin(address indexed newAdmin);
    event SetHubPool(address indexed newHubPool);
    event EnabledDepositRoute(address indexed originToken, uint256 indexed destinationChainId, bool enabled);
    event SetDepositQuoteTimeBuffer(uint32 newBuffer);
    event FundsDeposited(
        uint256 amount,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 indexed depositId,
        uint32 quoteTimestamp,
        address indexed originToken,
        address recipient,
        address indexed depositor,
        bytes message
    );
    event RequestedSpeedUpDeposit(
        int64 newRelayerFeePct,
        uint32 indexed depositId,
        address indexed depositor,
        address updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );
    event FilledRelay(
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 repaymentChainId,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 relayerFeePct,
        int64 realizedLpFeePct,
        uint32 indexed depositId,
        address destinationToken,
        address indexed relayer,
        address indexed depositor,
        address recipient,
        bytes message,
        RelayExecutionInfo updatableRelayData
    );

    event RelayedRootBundle(
        uint32 indexed rootBundleId,
        bytes32 indexed relayerRefundRoot,
        bytes32 indexed slowRelayRoot
    );
    event ExecutedRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        address caller
    );
    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        address indexed l2TokenAddress,
        address caller
    );
    event EmergencyDeleteRootBundle(uint256 indexed rootBundleId);
    event PausedDeposits(bool isPaused);
    event PausedFills(bool isPaused);

    /**
     * @notice Represents data used to fill a deposit.
     * @param relay Relay containing original data linked to deposit. Contains fields that can be
     * overridden by other parametersin the RelayExecution struct.
     * @param relayHash Hash of the relay data.
     * @param updatedRelayerFeePct Actual relayer fee pct to use for this relay.
     * @param updatedRecipient Actual recipient to use for this relay.
     * @param updatedMessage Actual message to use for this relay.
     * @param repaymentChainId Chain ID of the network that the relayer will receive refunds on.
     * @param maxTokensToSend Max number of tokens to pull from relayer.
     * @param maxCount Max count to protect the relayer from frontrunning.
     * @param slowFill Whether this is a slow fill.
     * @param payoutAdjustment Adjustment to the payout amount. Can be used to increase or decrease the payout to allow
     * for rewards or penalties. Used in slow fills.
     */
    struct RelayExecution {
        RelayData relay;
        bytes32 relayHash;
        int64 updatedRelayerFeePct;
        address updatedRecipient;
        bytes updatedMessage;
        uint256 repaymentChainId;
        uint256 maxTokensToSend;
        uint256 maxCount;
        bool slowFill;
        int256 payoutAdjustmentPct;
    }

    /**
     * @notice Packs together information to include in FilledRelay event.
     * @dev This struct is emitted as opposed to its constituent parameters due to the limit on number of
     * parameters in an event.
     * @param recipient Recipient of the relayed funds.
     * @param message Message included in the relay.
     * @param relayerFeePct Relayer fee pct used for this relay.
     * @param isSlowRelay Whether this is a slow relay.
     * @param payoutAdjustmentPct Adjustment to the payout amount.
     */
    struct RelayExecutionInfo {
        address recipient;
        bytes message;
        int64 relayerFeePct;
        bool isSlowRelay;
        int256 payoutAdjustmentPct;
    }

    /**
     * Do not leave an implementation contract uninitialized. An uninitialized implementation contract can be
     * taken over by an attacker, which may impact the proxy. To prevent the implementation contract from being
     * used, you should invoke the _disableInitializers function in the constructor to automatically lock it when
     * it is deployed:
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Construct the base SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     * @param _wrappedNativeTokenAddress wrappedNativeToken address for this network to set.
     */
    function __SpokePool_init(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool,
        address _wrappedNativeTokenAddress
    ) public onlyInitializing {
        numberOfDeposits = _initialDepositId;
        __EIP712_init("ACROSS-V2", "1.0.0");
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        depositQuoteTimeBuffer = 3600;
        _setCrossDomainAdmin(_crossDomainAdmin);
        _setHubPool(_hubPool);
        wrappedNativeToken = WETH9Interface(_wrappedNativeTokenAddress);
    }

    /****************************************
     *               MODIFIERS              *
     ****************************************/

    /**
     * @dev Function that should revert when `msg.sender` is not authorized to upgrade the contract. Called by
     * {upgradeTo} and {upgradeToAndCall}.
     * @dev This should be set to cross domain admin for specific SpokePool.
     */
    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    modifier unpausedDeposits() {
        require(!pausedDeposits, "Paused deposits");
        _;
    }

    modifier unpausedFills() {
        require(!pausedFills, "Paused fills");
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    // Allows cross domain admin to upgrade UUPS proxy implementation.
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    /**
     * @notice Pauses deposit-related functions. This is intended to be used if this contract is deprecated or when
     * something goes awry.
     * @dev Affects `deposit()` but not `speedUpDeposit()`, so that existing deposits can be sped up and still
     * relayed.
     * @param pause true if the call is meant to pause the system, false if the call is meant to unpause it.
     */
    function pauseDeposits(bool pause) public override onlyAdmin nonReentrant {
        pausedDeposits = pause;
        emit PausedDeposits(pause);
    }

    /**
     * @notice Pauses fill-related functions. This is intended to be used if this contract is deprecated or when
     * something goes awry.
     * @dev Affects fillRelayWithUpdatedDeposit() and fillRelay().
     * @param pause true if the call is meant to pause the system, false if the call is meant to unpause it.
     */
    function pauseFills(bool pause) public override onlyAdmin nonReentrant {
        pausedFills = pause;
        emit PausedFills(pause);
    }

    /**
     * @notice Change cross domain admin address. Callable by admin only.
     * @param newCrossDomainAdmin New cross domain admin.
     */
    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyAdmin nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    /**
     * @notice Change L1 hub pool address. Callable by admin only.
     * @param newHubPool New hub pool.
     */
    function setHubPool(address newHubPool) public override onlyAdmin nonReentrant {
        _setHubPool(newHubPool);
    }

    /**
     * @notice Enable/Disable an origin token => destination chain ID route for deposits. Callable by admin only.
     * @param originToken Token that depositor can deposit to this contract.
     * @param destinationChainId Chain ID for where depositor wants to receive funds.
     * @param enabled True to enable deposits, False otherwise.
     */
    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enabled
    ) public override onlyAdmin nonReentrant {
        enabledDepositRoutes[originToken][destinationChainId] = enabled;
        emit EnabledDepositRoute(originToken, destinationChainId, enabled);
    }

    /**
     * @notice Change allowance for deposit quote time to differ from current block time. Callable by admin only.
     * @param newDepositQuoteTimeBuffer New quote time buffer.
     */
    function setDepositQuoteTimeBuffer(uint32 newDepositQuoteTimeBuffer) public override onlyAdmin nonReentrant {
        depositQuoteTimeBuffer = newDepositQuoteTimeBuffer;
        emit SetDepositQuoteTimeBuffer(newDepositQuoteTimeBuffer);
    }

    /**
     * @notice This method stores a new root bundle in this contract that can be executed to refund relayers, fulfill
     * slow relays, and send funds back to the HubPool on L1. This method can only be called by the admin and is
     * designed to be called as part of a cross-chain message from the HubPool's executeRootBundle method.
     * @param relayerRefundRoot Merkle root containing relayer refund leaves that can be individually executed via
     * executeRelayerRefundLeaf().
     * @param slowRelayRoot Merkle root containing slow relay fulfillment leaves that can be individually executed via
     * executeSlowRelayLeaf().
     */
    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot) public override onlyAdmin nonReentrant {
        uint32 rootBundleId = uint32(rootBundles.length);
        RootBundle storage rootBundle = rootBundles.push();
        rootBundle.relayerRefundRoot = relayerRefundRoot;
        rootBundle.slowRelayRoot = slowRelayRoot;
        emit RelayedRootBundle(rootBundleId, relayerRefundRoot, slowRelayRoot);
    }

    /**
     * @notice This method is intended to only be used in emergencies where a bad root bundle has reached the
     * SpokePool.
     * @param rootBundleId Index of the root bundle that needs to be deleted. Note: this is intentionally a uint256
     * to ensure that a small input range doesn't limit which indices this method is able to reach.
     */
    function emergencyDeleteRootBundle(uint256 rootBundleId) public override onlyAdmin nonReentrant {
        // Deleting a struct containing a mapping does not delete the mapping in Solidity, therefore the bitmap's
        // data will still remain potentially leading to vulnerabilities down the line. The way around this would
        // be to iterate through every key in the mapping and resetting the value to 0, but this seems expensive and
        // would require a new list in storage to keep track of keys.
        //slither-disable-next-line mapping-deletion
        delete rootBundles[rootBundleId];
        emit EmergencyDeleteRootBundle(rootBundleId);
    }

    /**************************************
     *         DEPOSITOR FUNCTIONS        *
     **************************************/

    /**
     * @notice Called by user to bridge funds from origin to destination chain. Depositor will effectively lock
     * tokens in this contract and receive a destination token on the destination chain. The origin => destination
     * token mapping is stored on the L1 HubPool.
     * @notice The caller must first approve this contract to spend amount of originToken.
     * @notice The originToken => destinationChainId must be enabled.
     * @notice This method is payable because the caller is able to deposit native token if the originToken is
     * wrappedNativeToken and this function will handle wrapping the native token to wrappedNativeToken.
     * @param recipient Address to receive funds at on destination chain.
     * @param originToken Token to lock into this contract to initiate deposit.
     * @param amount Amount of tokens to deposit. Will be amount of tokens to receive less fees.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param relayerFeePct % of deposit amount taken out to incentivize a fast relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param maxCount used to protect the depositor from frontrunning to guarantee their quote remains valid.
     */
    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 maxCount
    ) public payable override nonReentrant unpausedDeposits {
        // Check that deposit route is enabled.
        require(enabledDepositRoutes[originToken][destinationChainId], "Disabled route");

        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(SignedMath.abs(relayerFeePct) < 0.5e18, "Invalid relayer fee");
        require(amount <= MAX_TRANSFER_SIZE, "Amount too large");
        require(depositCounter[originToken] <= maxCount, "Above max count");

        // This function assumes that L2 timing cannot be compared accurately and consistently to L1 timing. Therefore,
        // block.timestamp is different from the L1 EVM's. Therefore, the quoteTimestamp must be within a configurable
        // buffer of this contract's block time to allow for this variance.
        // Note also that quoteTimestamp cannot be less than the buffer otherwise the following arithmetic can result
        // in underflow. This isn't a problem as the deposit will revert, but the error might be unexpected for clients.

        //slither-disable-next-line timestamp
        require(
            getCurrentTime() >= quoteTimestamp - depositQuoteTimeBuffer &&
                getCurrentTime() <= quoteTimestamp + depositQuoteTimeBuffer,
            "invalid quote time"
        );

        // Increment count of deposits so that deposit ID for this spoke pool is unique.
        uint32 newDepositId = numberOfDeposits++;
        depositCounter[originToken] += amount;

        // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // transaction then the user is sending ETH. In this case, the ETH should be deposited to wrappedNativeToken.
        if (originToken == address(wrappedNativeToken) && msg.value > 0) {
            require(msg.value == amount, "msg.value must match amount");
            wrappedNativeToken.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the user's wallet as per normal.
            // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them.
            // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else IERC20Upgradeable(originToken).safeTransferFrom(msg.sender, address(this), amount);

        _emitDeposit(
            amount,
            chainId(),
            destinationChainId,
            relayerFeePct,
            newDepositId,
            quoteTimestamp,
            originToken,
            recipient,
            msg.sender,
            message
        );
    }

    /**
     * @notice Convenience method that depositor can use to signal to relayer to use updated fee.
     * @notice Relayer should only use events emitted by this function to submit fills with updated fees, otherwise they
     * risk their fills getting disputed for being invalid, for example if the depositor never actually signed the
     * update fee message.
     * @notice This function will revert if the depositor did not sign a message containing the updated fee for the
     * deposit ID stored in this contract. If the deposit ID is for another contract, or the depositor address is
     * incorrect, or the updated fee is incorrect, then the signature will not match and this function will revert.
     * @notice This function is not subject to a deposit pause on the off chance that deposits sent before all deposits
     * are paused have very low fees and the user wants to entice a relayer to fill them with a higher fee.
     * @param depositor Signer of the update fee message who originally submitted the deposit. If the deposit doesn't
     * exist, then the relayer will not be able to fill any relay, so the caller should validate that the depositor
     * did in fact submit a relay.
     * @param updatedRelayerFeePct New relayer fee that relayers can use.
     * @param depositId Deposit to update fee for that originated in this contract.
     * @param updatedRecipient New recipient address that should receive the tokens.
     * @param updatedMessage New message that should be provided to the recipient.
     * @param depositorSignature Signed message containing the depositor address, this contract chain ID, the updated
     * relayer fee %, and the deposit ID. This signature is produced by signing a hash of data according to the
     * EIP-712 standard. See more in the _verifyUpdateRelayerFeeMessage() comments.
     */
    function speedUpDeposit(
        address depositor,
        int64 updatedRelayerFeePct,
        uint32 depositId,
        address updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) public override nonReentrant {
        require(SignedMath.abs(updatedRelayerFeePct) < 0.5e18, "Invalid relayer fee");

        _verifyUpdateDepositMessage(
            depositor,
            depositId,
            chainId(),
            updatedRelayerFeePct,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );

        // Assuming the above checks passed, a relayer can take the signature and the updated relayer fee information
        // from the following event to submit a fill with an updated fee %.
        emit RequestedSpeedUpDeposit(
            updatedRelayerFeePct,
            depositId,
            depositor,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );
    }

    /**************************************
     *         RELAYER FUNCTIONS          *
     **************************************/

    /**
     * @notice Called by relayer to fulfill part of a deposit by sending destination tokens to the recipient.
     * Relayer is expected to pass in unique identifying information for deposit that they want to fulfill, and this
     * relay submission will be validated by off-chain data workers who can dispute this relay if any part is invalid.
     * If the relay is valid, then the relayer will be refunded on their desired repayment chain. If relay is invalid,
     * then relayer will not receive any refund.
     * @notice All of the deposit data can be found via on-chain events from the origin SpokePool, except for the
     * realizedLpFeePct which is a function of the HubPool's utilization at the deposit quote time. This fee %
     * is deterministic based on the quote time, so the relayer should just compute it using the canonical algorithm
     * as described in a UMIP linked to the HubPool's identifier.
     * @param depositor Depositor on origin chain who set this chain as the destination chain.
     * @param recipient Specified recipient on this chain.
     * @param destinationToken Token to send to recipient. Should be mapped to the origin token, origin chain ID
     * and this chain ID via a mapping on the HubPool.
     * @param amount Full size of the deposit.
     * @param maxTokensToSend Max amount of tokens to send recipient. If higher than amount, then caller will
     * send recipient the full relay amount.
     * @param repaymentChainId Chain of SpokePool where relayer wants to be refunded after the challenge window has
     * passed.
     * @param originChainId Chain of SpokePool where deposit originated.
     * @param realizedLpFeePct Fee % based on L1 HubPool utilization at deposit quote time. Deterministic based on
     * quote time.
     * @param relayerFeePct Fee % to keep as relayer, specified by depositor.
     * @param depositId Unique deposit ID on origin spoke pool.
     * @param message Message to send to recipient along with tokens.
     * @param maxCount Max count to protect the relayer from frontrunning.
     */
    function fillRelay(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        bytes memory message,
        uint256 maxCount
    ) public nonReentrant unpausedFills {
        // Each relay attempt is mapped to the hash of data uniquely identifying it, which includes the deposit data
        // such as the origin chain ID and the deposit ID, and the data in a relay attempt such as who the recipient
        // is, which chain and currency the recipient wants to receive funds on, and the relay fees.
        RelayExecution memory relayExecution = RelayExecution({
            relay: SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: chainId(),
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: relayerFeePct,
            updatedRecipient: recipient,
            updatedMessage: message,
            repaymentChainId: repaymentChainId,
            maxTokensToSend: maxTokensToSend,
            slowFill: false,
            payoutAdjustmentPct: 0,
            maxCount: maxCount
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        uint256 fillAmountPreFees = _fillRelay(relayExecution);
        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    /**
     * @notice Called by relayer to execute same logic as calling fillRelay except that relayer is using an updated
     * relayer fee %. The fee % must have been emitted in a message cryptographically signed by the depositor.
     * @notice By design, the depositor probably emitted the message with the updated fee by calling speedUpDeposit().
     * @param depositor Depositor on origin chain who set this chain as the destination chain.
     * @param recipient Specified recipient on this chain.
     * @param destinationToken Token to send to recipient. Should be mapped to the origin token, origin chain ID
     * and this chain ID via a mapping on the HubPool.
     * @param amount Full size of the deposit.
     * @param maxTokensToSend Max amount of tokens to send recipient. If higher than amount, then caller will
     * send recipient the full relay amount.
     * @param repaymentChainId Chain of SpokePool where relayer wants to be refunded after the challenge window has
     * passed.
     * @param originChainId Chain of SpokePool where deposit originated.
     * @param realizedLpFeePct Fee % based on L1 HubPool utilization at deposit quote time. Deterministic based on
     * quote time.
     * @param relayerFeePct Original fee % to keep as relayer set by depositor.
     * @param updatedRelayerFeePct New fee % to keep as relayer also specified by depositor.
     * @param depositId Unique deposit ID on origin spoke pool.
     * @param message Original message that was sent along with this deposit.
     * @param updatedMessage Modified message that the depositor signed when updating parameters.
     * @param depositorSignature Signed message containing the depositor address, this contract chain ID, the updated
     * relayer fee %, and the deposit ID. This signature is produced by signing a hash of data according to the
     * EIP-712 standard. See more in the _verifyUpdateRelayerFeeMessage() comments.
     * @param maxCount Max fill count to protect the relayer from frontrunning.
     */
    function fillRelayWithUpdatedDeposit(
        address depositor,
        address recipient,
        address updatedRecipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        int64 updatedRelayerFeePct,
        uint32 depositId,
        bytes memory message,
        bytes memory updatedMessage,
        bytes memory depositorSignature,
        uint256 maxCount
    ) public override nonReentrant unpausedFills {
        RelayExecution memory relayExecution = RelayExecution({
            relay: SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: chainId(),
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: updatedRelayerFeePct,
            updatedRecipient: updatedRecipient,
            updatedMessage: updatedMessage,
            repaymentChainId: repaymentChainId,
            maxTokensToSend: maxTokensToSend,
            slowFill: false,
            payoutAdjustmentPct: 0,
            maxCount: maxCount
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        _verifyUpdateDepositMessage(
            depositor,
            depositId,
            originChainId,
            updatedRelayerFeePct,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );
        uint256 fillAmountPreFees = _fillRelay(relayExecution);
        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    /**************************************
     *         DATA WORKER FUNCTIONS      *
     **************************************/

    /**
     * @notice Executes a slow relay leaf stored as part of a root bundle. Will send the full amount remaining in the
     * relay to the recipient, less fees.
     * @dev This function assumes that the relay's destination chain ID is the current chain ID, which prevents
     * the caller from executing a slow relay intended for another chain on this chain.
     * @param depositor Depositor on origin chain who set this chain as the destination chain.
     * @param recipient Specified recipient on this chain.
     * @param destinationToken Token to send to recipient. Should be mapped to the origin token, origin chain ID
     * and this chain ID via a mapping on the HubPool.
     * @param amount Full size of the deposit.
     * @param originChainId Chain of SpokePool where deposit originated.
     * @param realizedLpFeePct Fee % based on L1 HubPool utilization at deposit quote time. Deterministic based on
     * quote time.
     * @param relayerFeePct Original fee % to keep as relayer set by depositor.
     * @param depositId Unique deposit ID on origin spoke pool.
     * @param rootBundleId Unique ID of root bundle containing slow relay root that this leaf is contained in.
     * @param message Message to send to the recipient if the recipient is a contract.
     * @param payoutAdjustment Adjustment to the payout amount. Can be used to increase or decrease the payout to allow
     * for rewards or penalties.
     * @param proof Inclusion proof for this leaf in slow relay root in root bundle.
     */
    function executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes memory message,
        int256 payoutAdjustment,
        bytes32[] memory proof
    ) public virtual override nonReentrant {
        _executeSlowRelayLeaf(
            depositor,
            recipient,
            destinationToken,
            amount,
            originChainId,
            chainId(),
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            message,
            payoutAdjustment,
            proof
        );
    }

    /**
     * @notice Executes a relayer refund leaf stored as part of a root bundle. Will send the relayer the amount they
     * sent to the recipient plus a relayer fee.
     * @param rootBundleId Unique ID of root bundle containing relayer refund root that this leaf is contained in.
     * @param relayerRefundLeaf Contains all data necessary to reconstruct leaf contained in root bundle and to
     * refund relayer. This data structure is explained in detail in the SpokePoolInterface.
     * @param proof Inclusion proof for this leaf in relayer refund root in root bundle.
     */
    function executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public virtual override nonReentrant {
        _executeRelayerRefundLeaf(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *           VIEW FUNCTIONS           *
     **************************************/

    /**
     * @notice Returns chain ID for this network.
     * @dev Some L2s like ZKSync don't support the CHAIN_ID opcode so we allow the implementer to override this.
     */
    function chainId() public view virtual override returns (uint256) {
        return block.chainid;
    }

    /**
     * @notice Gets the current time.
     * @return uint for the current timestamp.
     */
    function getCurrentTime() public view virtual returns (uint256) {
        return block.timestamp; // solhint-disable-line not-rely-on-time
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    // Verifies inclusion proof of leaf in root, sends relayer their refund, and sends to HubPool any rebalance
    // transfers.
    function _executeRelayerRefundLeaf(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) internal {
        // Check integrity of leaf structure:
        require(relayerRefundLeaf.chainId == chainId(), "Invalid chainId");
        require(relayerRefundLeaf.refundAddresses.length == relayerRefundLeaf.refundAmounts.length, "invalid leaf");

        RootBundle storage rootBundle = rootBundles[rootBundleId];

        // Check that inclusionProof proves that relayerRefundLeaf is contained within the relayer refund root.
        // Note: This should revert if the relayerRefundRoot is uninitialized.
        require(MerkleLib.verifyRelayerRefund(rootBundle.relayerRefundRoot, relayerRefundLeaf, proof), "Bad Proof");

        // Verify the leafId in the leaf has not yet been claimed.
        require(!MerkleLib.isClaimed(rootBundle.claimedBitmap, relayerRefundLeaf.leafId), "Already claimed");

        // Set leaf as claimed in bitmap. This is passed by reference to the storage rootBundle.
        MerkleLib.setClaimed(rootBundle.claimedBitmap, relayerRefundLeaf.leafId);

        // Send each relayer refund address the associated refundAmount for the L2 token address.
        // Note: Even if the L2 token is not enabled on this spoke pool, we should still refund relayers.
        uint256 length = relayerRefundLeaf.refundAmounts.length;
        for (uint256 i = 0; i < length; ) {
            uint256 amount = relayerRefundLeaf.refundAmounts[i];
            if (amount > 0)
                IERC20Upgradeable(relayerRefundLeaf.l2TokenAddress).safeTransfer(
                    relayerRefundLeaf.refundAddresses[i],
                    amount
                );

            // OK because we assume refund array length won't be > types(uint256).max.
            // Based on the stress test results in /test/gas-analytics/SpokePool.RelayerRefundLeaf.ts, the UMIP should
            // limit the refund count in valid proposals to be ~800 so any RelayerRefundLeaves with > 800 refunds should
            // not make it to this stage.

            unchecked {
                ++i;
            }
        }

        // If leaf's amountToReturn is positive, then send L2 --> L1 message to bridge tokens back via
        // chain-specific bridging method.
        if (relayerRefundLeaf.amountToReturn > 0) {
            _bridgeTokensToHubPool(relayerRefundLeaf);

            emit TokensBridged(
                relayerRefundLeaf.amountToReturn,
                relayerRefundLeaf.chainId,
                relayerRefundLeaf.leafId,
                relayerRefundLeaf.l2TokenAddress,
                msg.sender
            );
        }

        emit ExecutedRelayerRefundRoot(
            relayerRefundLeaf.amountToReturn,
            relayerRefundLeaf.chainId,
            relayerRefundLeaf.refundAmounts,
            rootBundleId,
            relayerRefundLeaf.leafId,
            relayerRefundLeaf.l2TokenAddress,
            relayerRefundLeaf.refundAddresses,
            msg.sender
        );
    }

    // Verifies inclusion proof of leaf in root and sends recipient remainder of relay. Marks relay as filled.
    function _executeSlowRelayLeaf(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 realizedLpFeePct,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes memory message,
        int256 payoutAdjustmentPct,
        bytes32[] memory proof
    ) internal {
        RelayExecution memory relayExecution = RelayExecution({
            relay: SpokePoolInterface.RelayData({
                depositor: depositor,
                recipient: recipient,
                destinationToken: destinationToken,
                amount: amount,
                realizedLpFeePct: realizedLpFeePct,
                relayerFeePct: relayerFeePct,
                depositId: depositId,
                originChainId: originChainId,
                destinationChainId: destinationChainId,
                message: message
            }),
            relayHash: bytes32(0),
            updatedRelayerFeePct: 0,
            updatedRecipient: recipient,
            updatedMessage: message,
            repaymentChainId: 0,
            maxTokensToSend: amount,
            slowFill: true,
            payoutAdjustmentPct: payoutAdjustmentPct,
            maxCount: type(uint256).max
        });
        relayExecution.relayHash = _getRelayHash(relayExecution.relay);

        _verifySlowFill(relayExecution, rootBundleId, proof);

        // Note: use relayAmount as the max amount to send, so the relay is always completely filled by the contract's
        // funds in all cases. As this is a slow relay we set the relayerFeePct to 0. This effectively refunds the
        // relayer component of the relayerFee thereby only charging the depositor the LpFee.
        uint256 fillAmountPreFees = _fillRelay(relayExecution);

        // Note: Set repayment chain ID to 0 to indicate that there is no repayment to be made. The off-chain data
        // worker can use repaymentChainId=0 as a signal to ignore such relays for refunds. Also, set the relayerFeePct
        // to 0 as slow relays do not pay the caller of this method (depositor is refunded this fee).
        _emitFillRelay(relayExecution, fillAmountPreFees);
    }

    function _setCrossDomainAdmin(address newCrossDomainAdmin) internal {
        require(newCrossDomainAdmin != address(0), "Bad bridge router address");
        crossDomainAdmin = newCrossDomainAdmin;
        emit SetXDomainAdmin(newCrossDomainAdmin);
    }

    function _setHubPool(address newHubPool) internal {
        require(newHubPool != address(0), "Bad hub pool address");
        hubPool = newHubPool;
        emit SetHubPool(newHubPool);
    }

    // Should be overriden by implementing contract depending on how L2 handles sending tokens to L1.
    function _bridgeTokensToHubPool(SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf) internal virtual;

    function _verifyUpdateDepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        int64 updatedRelayerFeePct,
        address updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature
    ) internal view {
        // A depositor can request to modify an un-relayed deposit by signing a hash containing the updated
        // details and information uniquely identifying the deposit to relay. This information ensures
        // that this signature cannot be re-used for other deposits.
        // Note: We use the EIP-712 (https://eips.ethereum.org/EIPS/eip-712) standard for hashing and signing typed data.
        // Specifically, we use the version of the encoding known as "v4", as implemented by the JSON RPC method
        // `eth_signedTypedDataV4` in MetaMask (https://docs.metamask.io/guide/signing-data.html).
        bytes32 expectedTypedDataV4Hash = _hashTypedDataV4(
            // EIP-712 compliant hash struct: https://eips.ethereum.org/EIPS/eip-712#definition-of-hashstruct
            keccak256(
                abi.encode(
                    UPDATE_DEPOSIT_DETAILS_HASH,
                    depositId,
                    originChainId,
                    updatedRelayerFeePct,
                    updatedRecipient,
                    keccak256(updatedMessage)
                )
            ),
            // By passing in the origin chain id, we enable the verification of the signature on a different chain
            originChainId
        );
        _verifyDepositorSignature(depositor, expectedTypedDataV4Hash, depositorSignature);
    }

    // This function is isolated and made virtual to allow different L2's to implement chain specific recovery of
    // signers from signatures because some L2s might not support ecrecover. To be safe, consider always reverting
    // this function for L2s where ecrecover is different from how it works on Ethereum, otherwise there is the
    // potential to forge a signature from the depositor using a different private key than the original depositor's.
    function _verifyDepositorSignature(
        address depositor,
        bytes32 ethSignedMessageHash,
        bytes memory depositorSignature
    ) internal view virtual {
        // Note:
        // - We don't need to worry about reentrancy from a contract deployed at the depositor address since the method
        //   `SignatureChecker.isValidSignatureNow` is a view method. Re-entrancy can happen, but it cannot affect state.
        // - EIP-1271 signatures are supported. This means that a signature valid now, may not be valid later and vice-versa.
        // - For an EIP-1271 signature to work, the depositor contract address must map to a deployed contract on the destination
        //   chain that can validate the signature.
        // - Regular signatures from an EOA are also supported.
        bool isValid = SignatureChecker.isValidSignatureNow(depositor, ethSignedMessageHash, depositorSignature);
        require(isValid, "invalid signature");
    }

    function _verifySlowFill(
        RelayExecution memory relayExecution,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) internal view {
        SlowFill memory slowFill = SlowFill({
            relayData: relayExecution.relay,
            payoutAdjustmentPct: relayExecution.payoutAdjustmentPct
        });

        require(
            MerkleLib.verifySlowRelayFulfillment(rootBundles[rootBundleId].slowRelayRoot, slowFill, proof),
            "Invalid slow relay proof"
        );
    }

    function _computeAmountPreFees(uint256 amount, int64 feesPct) private pure returns (uint256) {
        return (1e18 * amount) / uint256((int256(1e18) - feesPct));
    }

    function _computeAmountPostFees(uint256 amount, int256 feesPct) private pure returns (uint256) {
        return (amount * uint256(int256(1e18) - feesPct)) / 1e18;
    }

    function _getRelayHash(SpokePoolInterface.RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(relayData));
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends wrappedNativeToken.
    function _unwrapwrappedNativeTokenTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20Upgradeable(address(wrappedNativeToken)).safeTransfer(to, amount);
        } else {
            wrappedNativeToken.withdraw(amount);
            //slither-disable-next-line arbitrary-send-eth
            to.transfer(amount);
        }
    }

    /**
     * @notice Caller specifies the max amount of tokens to send to user. Based on this amount and the amount of the
     * relay remaining (as stored in the relayFills mapping), pull the amount of tokens from the caller
     * and send to the recipient.
     * @dev relayFills keeps track of pre-fee fill amounts as a convenience to relayers who want to specify round
     * numbers for the maxTokensToSend parameter or convenient numbers like 100 (i.e. relayers who will fully
     * fill any relay up to 100 tokens, and partial fill with 100 tokens for larger relays).
     * @dev Caller must approve this contract to transfer up to maxTokensToSend of the relayData.destinationToken.
     * The amount to be sent might end up less if there is insufficient relay amount remaining to be sent.
     */
    function _fillRelay(RelayExecution memory relayExecution) internal returns (uint256 fillAmountPreFees) {
        RelayData memory relayData = relayExecution.relay;
        // We limit the relay fees to prevent the user spending all their funds on fees. Note that 0.5e18 (i.e. 50%)
        // fees are just magic numbers. The important point is to prevent the total fee from being 100%, otherwise
        // computing the amount pre fees runs into divide-by-0 issues.
        require(
            SignedMath.abs(relayExecution.updatedRelayerFeePct) < 0.5e18 &&
                SignedMath.abs(relayData.realizedLpFeePct) < 0.5e18,
            "invalid fees"
        );

        require(relayData.amount <= MAX_TRANSFER_SIZE, "Amount too large");

        // Check that the relay has not already been completely filled. Note that the relays mapping will point to
        // the amount filled so far for a particular relayHash, so this will start at 0 and increment with each fill.
        require(relayFills[relayExecution.relayHash] < relayData.amount, "relay filled");

        // This allows the caller to add in frontrunning protection for quote validity.
        require(fillCounter[relayData.destinationToken] <= relayExecution.maxCount, "Above max count");

        if (relayExecution.maxTokensToSend == 0) return 0;

        // Derive the amount of the relay filled if the caller wants to send exactly maxTokensToSend tokens to
        // the recipient. For example, if the user wants to send 10 tokens to the recipient, the full relay amount
        // is 100, and the fee %'s total 5%, then this computation would return ~10.5, meaning that to fill 10.5/100
        // of the full relay size, the caller would need to send 10 tokens to the user.
        // This is equivalent to the amount to be sent by the relayer before fees have been taken out.
        fillAmountPreFees = _computeAmountPreFees(
            relayExecution.maxTokensToSend,
            (relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct)
        );
        // If user's specified max amount to send is greater than the amount of the relay remaining pre-fees,
        // we'll pull exactly enough tokens to complete the relay.
        uint256 amountToSend = relayExecution.maxTokensToSend;
        uint256 amountRemainingInRelay = relayData.amount - relayFills[relayExecution.relayHash];
        if (amountRemainingInRelay < fillAmountPreFees) {
            fillAmountPreFees = amountRemainingInRelay;

            // The user will fulfill the remainder of the relay, so we need to compute exactly how many tokens post-fees
            // that they need to send to the recipient. Note that if the relayer is filled using contract funds then
            // this is a slow relay.
            amountToSend = _computeAmountPostFees(
                fillAmountPreFees,
                relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct
            );

            if (relayExecution.payoutAdjustmentPct != 0) {
                // If payoutAdjustmentPct is positive, then the recipient will receive more than the amount they
                // were originally expecting. If it is negative, then the recipient will receive less.
                // -1e18 is -100%. Because we cannot pay out negative values, that is the minimum.
                require(relayExecution.payoutAdjustmentPct >= -1e18, "payoutAdjustmentPct too small");

                // Note: since _computeAmountPostFees is typicaly intended for fees, the signage must be reversed.
                amountToSend = _computeAmountPostFees(amountToSend, -relayExecution.payoutAdjustmentPct);
            }
        }

        // Update fill counter.
        _updateCountFromFill(
            relayFills[relayExecution.relayHash],
            relayFills[relayExecution.relayHash] + fillAmountPreFees,
            relayData.amount,
            relayData.realizedLpFeePct,
            relayData.destinationToken,
            relayExecution.slowFill
        );

        // relayFills keeps track of pre-fee fill amounts as a convenience to relayers who want to specify round
        // numbers for the maxTokensToSend parameter or convenient numbers like 100 (i.e. relayers who will fully
        // fill any relay up to 100 tokens, and partial fill with 100 tokens for larger relays).
        relayFills[relayExecution.relayHash] += fillAmountPreFees;

        // If relayer and receiver are the same address, there is no need to do any transfer, as it would result in no
        // net movement of funds.
        // Note: this is important because it means that relayers can intentionally self-relay in a capital efficient
        // way (no need to have funds on the destination).
        if (msg.sender == relayData.recipient) return fillAmountPreFees;

        // If relay token is wrappedNativeToken then unwrap and send native token.
        if (relayData.destinationToken == address(wrappedNativeToken)) {
            // Note: useContractFunds is True if we want to send funds to the recipient directly out of this contract,
            // otherwise we expect the caller to send funds to the recipient. If useContractFunds is True and the
            // recipient wants wrappedNativeToken, then we can assume that wrappedNativeToken is already in the
            // contract, otherwise we'll need the user to send wrappedNativeToken to this contract. Regardless, we'll
            // need to unwrap it to native token before sending to the user.
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapwrappedNativeTokenTo(payable(relayData.recipient), amountToSend);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else {
            // Note: Similar to note above, send token directly from the contract to the user in the slow relay case.
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(
                    msg.sender,
                    relayData.recipient,
                    amountToSend
                );
            else IERC20Upgradeable(relayData.destinationToken).safeTransfer(relayData.recipient, amountToSend);
        }

        if (relayData.recipient.isContract() && relayData.message.length > 0) {
            AcrossMessageHandler(relayData.recipient).handleAcrossMessage(
                relayData.destinationToken,
                amountToSend,
                relayData.message
            );
        }
    }

    function _updateCountFromFill(
        uint256 startingFillAmount,
        uint256 endingFillAmount,
        uint256 totalFillAmount,
        int64 realizedLPFeePct,
        address token,
        bool useContractFunds
    ) internal {
        // If this is a slow fill, it's an initial 0-fill, or a partial fill has already happened, do nothing, as these
        // should not impact the count.
        if (useContractFunds || endingFillAmount == 0 || startingFillAmount > 0) return;
        fillCounter[token] += _computeAmountPostFees(totalFillAmount, realizedLPFeePct);
    }

    // The following internal methods emit events with many params to overcome solidity stack too deep issues.
    function _emitFillRelay(RelayExecution memory relayExecution, uint256 fillAmountPreFees) internal {
        RelayExecutionInfo memory relayExecutionInfo = RelayExecutionInfo({
            relayerFeePct: relayExecution.updatedRelayerFeePct,
            recipient: relayExecution.updatedRecipient,
            message: relayExecution.updatedMessage,
            isSlowRelay: relayExecution.slowFill,
            payoutAdjustmentPct: relayExecution.payoutAdjustmentPct
        });

        emit FilledRelay(
            relayExecution.relay.amount,
            relayFills[relayExecution.relayHash],
            fillAmountPreFees,
            relayExecution.repaymentChainId,
            relayExecution.relay.originChainId,
            relayExecution.relay.destinationChainId,
            relayExecution.relay.relayerFeePct,
            relayExecution.relay.realizedLpFeePct,
            relayExecution.relay.depositId,
            relayExecution.relay.destinationToken,
            msg.sender,
            relayExecution.relay.depositor,
            relayExecution.relay.recipient,
            relayExecution.relay.message,
            relayExecutionInfo
        );
    }

    function _emitDeposit(
        uint256 amount,
        uint256 originChainId,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 depositId,
        uint32 quoteTimestamp,
        address originToken,
        address recipient,
        address depositor,
        bytes memory message
    ) internal {
        emit FundsDeposited(
            amount,
            originChainId,
            destinationChainId,
            relayerFeePct,
            depositId,
            quoteTimestamp,
            originToken,
            recipient,
            depositor,
            message
        );
    }

    // Implementing contract needs to override this to ensure that only the appropriate cross chain admin can execute
    // certain admin functions. For L2 contracts, the cross chain admin refers to some L1 address or contract, and for
    // L1, this would just be the same admin of the HubPool.
    function _requireAdminSender() internal virtual;

    // Added to enable the this contract to receive native token (ETH). Used when unwrapping wrappedNativeToken.
    receive() external payable {}

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[1000] private __gap;
}
