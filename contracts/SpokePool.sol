// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./external/interfaces/WETH9Interface.sol";
import "./interfaces/SpokePoolInterface.sol";
import "./interfaces/V3SpokePoolInterface.sol";
import "./upgradeable/MultiCallerUpgradeable.sol";
import "./upgradeable/EIP712CrossChainUpgradeable.sol";
import "./upgradeable/AddressLibUpgradeable.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

// This interface is expected to be implemented by any contract that expects to receive messages from the SpokePool.
interface AcrossMessageHandler {
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function handleAcrossMessage(
        address tokenSent,
        uint256 amount,
        bool fillCompleted,
        address relayer,
        bytes memory message
    ) external;

    // New function interface to be used with V3 functions since fillCompleted no longer has any
    // meaning now that partial fills are impossible.
    function handleV3AcrossMessage(
        address tokenSent,
        uint256 amount,
        address relayer,
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
    V3SpokePoolInterface,
    SpokePoolInterface,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    MultiCallerUpgradeable,
    EIP712CrossChainUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressLibUpgradeable for address;

    // Address of the L1 contract that acts as the owner of this SpokePool. This should normally be set to the HubPool
    // address. The crossDomainAdmin address is unused when the SpokePool is deployed to the same chain as the HubPool.
    address public crossDomainAdmin;

    // Address of the L1 contract that will send tokens to and receive tokens from this contract to fund relayer
    // refunds and slow relays.
    address public hubPool;

    // Note: The following two storage variables prefixed with DEPRECATED used to be variables that could be set by
    // the cross-domain admin. Admins ended up not changing these in production, so to reduce
    // gas in deposit/fill functions, we are converting them to private variables to maintain the contract
    // storage layout and replacing them with immutable or constant variables, because retrieving a constant
    // value is cheaper than retrieving a storage variable. Please see out the immutable/constant variable section.
    WETH9Interface private DEPRECATED_wrappedNativeToken;
    uint32 private DEPRECATED_depositQuoteTimeBuffer;

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
    mapping(bytes32 => uint256) private DEPRECATED_relayFills;

    // Note: We will likely un-deprecate the fill and deposit counters to implement a better
    // dynamic LP fee mechanism but for now we'll deprecate it to reduce bytecode
    // in deposit/fill functions. These counters are designed to implement a fee mechanism that is based on a
    // canonical history of deposit and fill events and how they update a virtual running balance of liabilities and
    // assets, which then determines the LP fee charged to relays.

    // This keeps track of the worst-case liabilities due to fills.
    // It is never reset. Users should only rely on it to determine the worst-case increase in liabilities between
    // two points. This is used to provide frontrunning protection to ensure the relayer's assumptions about the state
    // upon which their expected repayments are based will not change before their transaction is mined.
    mapping(address => uint256) private DEPRECATED_fillCounter;

    // This keeps track of the total running deposits for each token. This allows depositors to protect themselves from
    // frontrunning that might change their worst-case quote.
    mapping(address => uint256) private DEPRECATED_depositCounter;

    // This tracks the number of identical refunds that have been requested.
    // The intention is to allow an off-chain system to know when this could be a duplicate and ensure that the other
    // requests are known and accounted for.
    mapping(bytes32 => uint256) private DEPRECATED_refundsRequested;

    // Mapping of V3 relay hashes to fill statuses. Distinguished from relayFills
    // to eliminate any chance of collision between pre and post V3 relay hashes.
    mapping(bytes32 => uint256) public fillStatuses;

    /**************************************************************
     *                CONSTANT/IMMUTABLE VARIABLES                *
     **************************************************************/
    // Constant and immutable variables do not take up storage slots and are instead added to the contract bytecode
    // at compile time. The difference between them is that constant variables must be declared inline, meaning
    // that they cannot be changed in production without changing the contract code, while immutable variables
    // can be set in the constructor. Therefore we use the immutable keyword for variables that we might want to be
    // different for each child contract (one obvious example of this is the wrappedNativeToken) or that we might
    // want to update in the future like depositQuoteTimeBuffer. Constants are unlikely to ever be changed.

    // Address of wrappedNativeToken contract for this network. If an origin token matches this, then the caller can
    // optionally instruct this contract to wrap native tokens when depositing (ie ETH->WETH or MATIC->WMATIC).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    WETH9Interface public immutable wrappedNativeToken;

    // Any deposit quote times greater than or less than this value to the current contract time is blocked. Forces
    // caller to use an approximately "current" realized fee.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable depositQuoteTimeBuffer;

    // The fill deadline can only be set this far into the future from the timestamp of the deposit on this contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint32 public immutable fillDeadlineBuffer;

    uint256 public constant MAX_TRANSFER_SIZE = 1e36;

    // Note: this needs to be larger than the max transfer size to ensure that all slow fills are fillable, even if
    // their fees are negative.
    // It's important that it isn't too large, however, as it should be multipliable by ~2e18 without overflowing.
    // 1e40 * 2e18 = 2e58 << 2^255 ~= 5e76
    /// @custom:audit FOLLOWING VARIABLE TO BE DEPRECATED
    uint256 public constant SLOW_FILL_MAX_TOKENS_TO_SEND = 1e40;

    // Set max payout adjustment to something
    /// @custom:audit FOLLOWING VARIABLE TO BE DEPRECATED
    bytes32 public constant UPDATE_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,int64 updatedRelayerFeePct,address updatedRecipient,bytes updatedMessage)"
        );

    bytes32 public constant UPDATE_V3_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,uint256 updatedOutputAmount,address updatedRecipient,bytes updatedMessage)"
        );
    /****************************************
     *                EVENTS                *
     ****************************************/
    event SetXDomainAdmin(address indexed newAdmin);
    event SetHubPool(address indexed newHubPool);
    event EnabledDepositRoute(address indexed originToken, uint256 indexed destinationChainId, bool enabled);
    /// @custom:audit FOLLOWING EVENT TO BE DEPRECATED
    event FundsDeposited(
        uint256 amount,
        uint256 originChainId,
        uint256 indexed destinationChainId,
        int64 relayerFeePct,
        uint32 indexed depositId,
        uint32 quoteTimestamp,
        address originToken,
        address recipient,
        address indexed depositor,
        bytes message
    );
    /// @custom:audit FOLLOWING EVENT TO BE DEPRECATED
    event RequestedSpeedUpDeposit(
        int64 newRelayerFeePct,
        uint32 indexed depositId,
        address indexed depositor,
        address updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );
    /// @custom:audit FOLLOWING EVENT TO BE DEPRECATED
    event FilledRelay(
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint256 destinationChainId,
        int64 relayerFeePct,
        int64 realizedLpFeePct,
        uint32 indexed depositId,
        address destinationToken,
        address relayer,
        address indexed depositor,
        address recipient,
        bytes message,
        RelayExecutionInfo updatableRelayData
    );
    /// @custom:audit FOLLOWING EVENT TO BE DEPRECATED
    event RefundRequested(
        address indexed relayer,
        address refundToken,
        uint256 amount,
        uint256 indexed originChainId,
        uint256 destinationChainId,
        int64 realizedLpFeePct,
        uint32 indexed depositId,
        uint256 fillBlock,
        uint256 previousIdenticalRequests
    );
    event RelayedRootBundle(
        uint32 indexed rootBundleId,
        bytes32 indexed relayerRefundRoot,
        bytes32 indexed slowRelayRoot
    );
    /// @custom:audit FOLLOWING EVENT TO BE DEPRECATED
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
     * overridden by other parameters in the RelayExecution struct.
     * @param relayHash Hash of the relay data.
     * @param updatedRelayerFeePct Actual relayer fee pct to use for this relay.
     * @param updatedRecipient Actual recipient to use for this relay.
     * @param updatedMessage Actual message to use for this relay.
     * @param repaymentChainId Chain ID of the network that the relayer will receive refunds on.
     * @param maxTokensToSend Max number of tokens to pull from relayer.
     * @param maxCount Max count to protect the relayer from frontrunning.
     * @param slowFill Whether this is a slow fill.
     * @param payoutAdjustmentPct Adjustment to the payout amount. Can be used to increase or decrease the payout to
     * allow for rewards or penalties. Used in slow fills.
     */
    /// @custom:audit FOLLOWING STRUCT TO BE DEPRECATED
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
    /// @custom:audit FOLLOWING STRUCT TO BE DEPRECATED
    struct RelayExecutionInfo {
        address recipient;
        bytes message;
        int64 relayerFeePct;
        bool isSlowRelay;
        int256 payoutAdjustmentPct;
    }

    /**
     * @notice Construct the SpokePool. Normally, logic contracts used in upgradeable proxies shouldn't
     * have constructors since the following code will be executed within the logic contract's state, not the
     * proxy contract's state. However, if we restrict the constructor to setting only immutable variables, then
     * we are safe because immutable variables are included in the logic contract's bytecode rather than its storage.
     * @dev Do not leave an implementation contract uninitialized. An uninitialized implementation contract can be
     * taken over by an attacker, which may impact the proxy. To prevent the implementation contract from being
     * used, you should invoke the _disableInitializers function in the constructor to automatically lock it when
     * it is deployed:
     * @param _wrappedNativeTokenAddress wrappedNativeToken address for this network to set.
     * @param _depositQuoteTimeBuffer depositQuoteTimeBuffer to set. Quote timestamps can't be set more than this amount
     * into the past from the block time of the deposit.
     * @param _fillDeadlineBuffer fillDeadlineBuffer to set. Fill deadlines can't be set more than this amount
     * into the future from the block time of the deposit.
     */
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wrappedNativeTokenAddress,
        uint32 _depositQuoteTimeBuffer,
        uint32 _fillDeadlineBuffer
    ) {
        wrappedNativeToken = WETH9Interface(_wrappedNativeTokenAddress);
        depositQuoteTimeBuffer = _depositQuoteTimeBuffer;
        fillDeadlineBuffer = _fillDeadlineBuffer;
        _disableInitializers();
    }

    /**
     * @notice Construct the base SpokePool.
     * @param _initialDepositId Starting deposit ID. Set to 0 unless this is a re-deployment in order to mitigate
     * relay hash collisions.
     * @param _crossDomainAdmin Cross domain admin to set. Can be changed by admin.
     * @param _hubPool Hub pool address to set. Can be changed by admin.
     */
    function __SpokePool_init(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _hubPool
    ) public onlyInitializing {
        numberOfDeposits = _initialDepositId;
        __EIP712_init("ACROSS-V2", "1.0.0");
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setCrossDomainAdmin(_crossDomainAdmin);
        _setHubPool(_hubPool);
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
     */
    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 // maxCount. Deprecated.
    ) public payable override nonReentrant unpausedDeposits {
        _deposit(
            msg.sender,
            recipient,
            originToken,
            amount,
            destinationChainId,
            relayerFeePct,
            quoteTimestamp,
            message
        );
    }

    /**
     * @notice The only difference between depositFor and deposit is that the depositor address stored
     * in the relay hash can be overridden by the caller. This means that the passed in depositor
     * can speed up the deposit, which is useful if the deposit is taken from the end user to a middle layer
     * contract, like an aggregator or the SpokePoolVerifier, before calling deposit on this contract.
     * @notice The caller must first approve this contract to spend amount of originToken.
     * @notice The originToken => destinationChainId must be enabled.
     * @notice This method is payable because the caller is able to deposit native token if the originToken is
     * wrappedNativeToken and this function will handle wrapping the native token to wrappedNativeToken.
     * @param depositor Address who is credited for depositing funds on origin chain and can speed up the deposit.
     * @param recipient Address to receive funds at on destination chain.
     * @param originToken Token to lock into this contract to initiate deposit.
     * @param amount Amount of tokens to deposit. Will be amount of tokens to receive less fees.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param relayerFeePct % of deposit amount taken out to incentivize a fast relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     */
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function depositFor(
        address depositor,
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message,
        uint256 // maxCount. Deprecated.
    ) public payable nonReentrant unpausedDeposits {
        _deposit(depositor, recipient, originToken, amount, destinationChainId, relayerFeePct, quoteTimestamp, message);
    }

    /**
     * @notice This is a simple wrapper for deposit() that sets the quoteTimestamp to the current SpokePool timestamp.
     * @notice This function is intended for multisig depositors who can accept some LP fee uncertainty in order to lift
     * the quoteTimestamp buffer constraint.
     * @dev Re-orgs may produce invalid fills if the quoteTimestamp moves across a change in HubPool utilisation.
     * @dev The existing function modifiers are already enforced by _deposit(), so no additional modifiers are imposed.
     * @param recipient Address to receive funds at on destination chain.
     * @param originToken Token to lock into this contract to initiate deposit.
     * @param amount Amount of tokens to deposit. Will be amount of tokens to receive less fees.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param relayerFeePct % of deposit amount taken out to incentivize a fast relayer.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param maxCount used to protect the depositor from frontrunning to guarantee their quote remains valid.
     */
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function depositNow(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        bytes memory message,
        uint256 maxCount
    ) public payable {
        deposit(
            recipient,
            originToken,
            amount,
            destinationChainId,
            relayerFeePct,
            uint32(getCurrentTime()),
            message,
            maxCount
        );
    }

    /**
     * @notice This is a simple wrapper for depositFor() that sets the quoteTimestamp to the current SpokePool timestamp.
     * @notice This function is intended for multisig depositors who can accept some LP fee uncertainty in order to lift
     * the quoteTimestamp buffer constraint.
     * @dev Re-orgs may produce invalid fills if the quoteTimestamp moves across a change in HubPool utilisation.
     * @dev The existing function modifiers are already enforced by _deposit(), so no additional modifiers are imposed.
     * @param depositor Address who is credited for depositing funds on origin chain and can speed up the deposit.
     * @param recipient Address to receive funds at on destination chain.
     * @param originToken Token to lock into this contract to initiate deposit.
     * @param amount Amount of tokens to deposit. Will be amount of tokens to receive less fees.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param relayerFeePct % of deposit amount taken out to incentivize a fast relayer.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param maxCount used to protect the depositor from frontrunning to guarantee their quote remains valid.
     */
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function depositForNow(
        address depositor,
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        bytes memory message,
        uint256 maxCount
    ) public payable {
        depositFor(
            depositor,
            recipient,
            originToken,
            amount,
            destinationChainId,
            relayerFeePct,
            uint32(getCurrentTime()),
            message,
            maxCount
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
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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

    /********************************************
     *         V3 DEPOSITOR FUNCTIONS          *
     ********************************************/

    /**
     * @notice Request to bridge input token cross chain to a destination chain and receive a specified amount
     * of output tokens. The fee paid to relayers and the system should be captured in the spread between output
     * amount and input amount when adjusted to be denominated in the input token. A relayer on the destination
     * chain will send outputAmount of outputTokens to the recipient and receive inputTokens on a repayment
     * chain of their choice. Therefore, the fee should account for destination fee transaction costs,
     * the relayer's opportunity cost of capital while they wait to be refunded following an optimistic challenge
     * window in the HubPool, and the system fee that they'll be charged.
     * @dev On the destination chain, the hash of the deposit data will be used to uniquely identify this deposit, so
     * modifying any params in it will result in a different hash and a different deposit. The hash will comprise
     * all parameters to this function along with this chain's chainId(). Relayers are only refunded for filling
     * deposits with deposit hashes that map exactly to the one emitted by this contract.
     * @param depositor The account credited with the deposit who can request to "speed up" this deposit by modifying
     * the output amount, recipient, and message.
     * @param recipient The account receiving funds on the destination chain. Can be an EOA or a contract. If
     * the output token is the wrapped native token for the chain, then the recipient will receive native token if
     * an EOA or wrapped native token if a contract.
     * @param inputToken The token pulled from the caller's account and locked into this contract to
     * initiate the deposit. The equivalent of this token on the relayer's repayment chain of choice will be sent
     * as a refund. If this is equal to the wrapped native token then the caller can optionally pass in native token as
     * msg.value, as long as msg.value = inputTokenAmount.
     * @param outputToken The token that the relayer will send to the recipient on the destination chain. Must be an
     * ERC20.
     * @param inputAmount The amount of input tokens to pull from the caller's account and lock into this contract.
     * This amount will be sent to the relayer on their repayment chain of choice as a refund following an optimistic
     * challenge window in the HubPool, plus a system fee.
     * @param outputAmount The amount of output tokens that the relayer will send to the recipient on the destination.
     * @param destinationChainId The destination chain identifier. Must be enabled along with the input token
     * as a valid deposit route from this spoke pool or this transaction will revert.
     * @param exclusiveRelayer The relayer that will be exclusively allowed to fill this deposit before the
     * exclusivity deadline timestamp.
     * @param quoteTimestamp The HubPool timestamp that is used to determine the system fee paid by the depositor.
     *  This must be set to some time between [currentTime - depositQuoteTimeBuffer, currentTime]
     * where currentTime is block.timestamp on this chain or this transaction will revert.
     * @param fillDeadline The deadline for the relayer to fill the deposit. After this destination chain timestamp,
     * the fill will revert on the destination chain. Must be set between [currentTime, currentTime + fillDeadlineBuffer]
     * where currentTime is block.timestamp on this chain or this transaction will revert.
     * @param exclusivityDeadline The deadline for the exclusive relayer to fill the deposit. After this
     * destination chain timestamp, anyone can fill this deposit on the destination chain.
     * @param message The message to send to the recipient on the destination chain if the recipient is a contract.
     * If the message is not empty, the recipient contract must implement handleV3AcrossMessage() or the fill will revert.
     */
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) public payable override nonReentrant unpausedDeposits {
        // Check that deposit route is enabled for the input token. There are no checks required for the output token
        // which is pulled from the relayer at fill time and passed through this contract atomically to the recipient.
        if (!enabledDepositRoutes[inputToken][destinationChainId]) revert DisabledRoute();

        // Require that quoteTimestamp has a maximum age so that depositors pay an LP fee based on recent HubPool usage.
        // It is assumed that cross-chain timestamps are normally loosely in-sync, but clock drift can occur. If the
        // SpokePool time stalls or lags significantly, it is still possible to make deposits by setting quoteTimestamp
        // within the configured buffer. The owner should pause deposits/fills if this is undesirable.
        // This will underflow if quoteTimestamp is more than depositQuoteTimeBuffer;
        // this is safe but will throw an unintuitive error.

        // slither-disable-next-line timestamp
        if (getCurrentTime() - quoteTimestamp > depositQuoteTimeBuffer) revert InvalidQuoteTimestamp();

        // fillDeadline is relative to the destination chain.
        // Don’t allow fillDeadline to be more than several bundles into the future.
        // This limits the maximum required lookback for dataworker and relayer instances.
        if (fillDeadline > getCurrentTime() + fillDeadlineBuffer) revert InvalidFillDeadline();

        // No need to sanity check exclusivityDeadline because if its bigger than fillDeadline, then
        // there the full deadline is exclusive, and if its too small, then there is no exclusivity period.

        // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // transaction then the user is sending the native token. In this case, the native token should be
        // wrapped.
        if (inputToken == address(wrappedNativeToken) && msg.value > 0) {
            if (msg.value != inputAmount) revert MsgValueDoesNotMatchInputAmount();
            wrappedNativeToken.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the caller as per normal.
            // Note: this includes the case where the L2 caller has WETH (already wrapped ETH) and wants to bridge them.
            // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else IERC20Upgradeable(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);

        emit V3FundsDeposited(
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            // Increment count of deposits so that deposit ID for this spoke pool is unique.
            numberOfDeposits++,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            depositor,
            recipient,
            exclusiveRelayer,
            message
        );
    }

    /**
     * @notice Depositor can use this function to signal to relayer to use updated output amount, recipient,
     * and/or message.
     * @dev the depositor and depositId must match the params in a V3FundsDeposited event that the depositor
     * wants to speed up. The relayer has the option but not the obligation to use this updated information
     * when filling the deposit via fillV3RelayWithUpdatedDeposit().
     * @param depositor Depositor that must sign the depositorSignature and was the original depositor.
     * @param depositId Deposit ID to speed up.
     * @param updatedOutputAmount New output amount to use for this deposit. Should be lower than previous value
     * otherwise relayer has no incentive to use this updated value.
     * @param updatedRecipient New recipient to use for this deposit. Can be modified if the recipient is a contract
     * that expects to receive a message from the relay and for some reason needs to be modified.
     * @param updatedMessage New message to use for this deposit. Can be modified if the recipient is a contract
     * that expects to receive a message from the relay and for some reason needs to be modified.
     * @param depositorSignature Signed EIP712 hashstruct containing the deposit ID. Should be signed by the depositor
     * account. If depositor is a contract, then should implement EIP1271 to sign as a contract. See
     * _verifyUpdateV3DepositMessage() for more details about how this signature should be constructed.
     */
    function speedUpV3Deposit(
        address depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) public override nonReentrant {
        _verifyUpdateV3DepositMessage(
            depositor,
            depositId,
            chainId(),
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );

        // Assuming the above checks passed, a relayer can take the signature and the updated deposit information
        // from the following event to submit a fill with updated relay data.
        emit RequestedSpeedUpV3Deposit(
            updatedOutputAmount,
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
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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

    /******************************************
     *         V3 RELAYER FUNCTIONS          *
     ******************************************/

    /**
     * @notice Fulfill request to bridge cross chain by sending specified output tokens to the recipient.
     * @dev The fee paid to relayers and the system should be captured in the spread between output
     * amount and input amount when adjusted to be denominated in the input token. A relayer on the destination
     * chain will send outputAmount of outputTokens to the recipient and receive inputTokens on a repayment
     * chain of their choice. Therefore, the fee should account for destination fee transaction costs, the
     * relayer's opportunity cost of capital while they wait to be refunded following an optimistic challenge
     * window in the HubPool, and a system fee charged to relayers.
     * @dev The hash of the relayData will be used to uniquely identify the deposit to fill, so
     * modifying any params in it will result in a different hash and a different deposit. The hash will comprise
     * all parameters passed to depositV3() on the origin chain along with that chain's chainId(). This chain's
     * chainId() must therefore match the destinationChainId passed into depositV3.
     * Relayers are only refunded for filling deposits with deposit hashes that map exactly to the one emitted by the
     * origin SpokePool therefore the relayer should not modify any params in relayData.
     * @dev Cannot fill more than once. Partial fills are not supported.
     * @param relayData struct containing all the data needed to identify the deposit to be filled. Should match
     * all the same-named parameters emitted in the origin chain V3FundsDeposited event.
     * - depositor: The account credited with the deposit who can request to "speed up" this deposit by modifying
     * the output amount, recipient, and message.
     * - recipient The account receiving funds on this chain. Can be an EOA or a contract. If
     * the output token is the wrapped native token for the chain, then the recipient will receive native token if
     * an EOA or wrapped native token if a contract.
     * - inputToken: The token pulled from the caller's account to initiate the deposit. The equivalent of this
     * token on the repayment chain will be sent as a refund to the caller.
     * - outputToken The token that the caller will send to the recipient on the destination chain. Must be an
     * ERC20.
     * - inputAmount: This amount, less a system fee, will be sent to the caller on their repayment chain of choice as a refund
     * following an optimistic challenge window in the HubPool.
     * - outputAmount: The amount of output tokens that the caller will send to the recipient.
     * - originChainId: The origin chain identifier.
     * - exclusiveRelayer The relayer that will be exclusively allowed to fill this deposit before the
     * exclusivity deadline timestamp.
     * - fillDeadline The deadline for the caller to fill the deposit. After this timestamp,
     * the fill will revert on the destination chain.
     * - exclusivityDeadline: The deadline for the exclusive relayer to fill the deposit. After this
     * timestamp, anyone can fill this deposit.
     * - message The message to send to the recipient if the recipient is a contract that implements a
     * handleV3AcrossMessage() public function
     * @param repaymentChainId Chain of SpokePool where relayer wants to be refunded after the challenge window has
     * passed. Will receive inputAmount of the equivalent token to inputToken on the repayment chain.
     */
    function fillV3Relay(V3RelayData calldata relayData, uint256 repaymentChainId)
        public
        override
        nonReentrant
        unpausedFills
    {
        // Exclusivity deadline is inclusive and is the latest timestamp that the exclusive relayer has sole right
        // to fill the relay.
        if (relayData.exclusiveRelayer != msg.sender && relayData.exclusivityDeadline >= getCurrentTime()) {
            revert NotExclusiveRelayer();
        }

        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: _getV3RelayHash(relayData),
            updatedOutputAmount: relayData.outputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: repaymentChainId
        });

        _fillRelayV3(relayExecution, msg.sender, false);
    }

    /**
     * @notice Identical to fillV3Relay except that the relayer wants to use a depositor's updated output amount,
     * recipient, and/or message. The relayer should only use this function if they can supply a message signed
     * by the depositor that contains the fill's matching deposit ID along with updated relay parameters.
     * If the signature can be verified, then this function will emit a FilledV3Event that will be used by
     * the system for refund verification purposes. In otherwords, this function is an alternative way to fill a
     * a deposit than fillV3Relay.
     * @dev Subject to same exclusivity deadline rules as fillV3Relay().
     * @param relayData struct containing all the data needed to identify the deposit to be filled. See fillV3Relay().
     * @param repaymentChainId Chain of SpokePool where relayer wants to be refunded after the challenge window has
     * passed. See fillV3Relay().
     * @param updatedOutputAmount New output amount to use for this deposit.
     * @param updatedRecipient New recipient to use for this deposit.
     * @param updatedMessage New message to use for this deposit.
     * @param depositorSignature Signed EIP712 hashstruct containing the deposit ID. Should be signed by the depositor
     * account.
     */
    function fillV3RelayWithUpdatedDeposit(
        V3RelayData calldata relayData,
        uint256 repaymentChainId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) public override nonReentrant unpausedFills {
        // Exclusivity deadline is inclusive and is the latest timestamp that the exclusive relayer has sole right
        // to fill the relay.
        if (relayData.exclusiveRelayer != msg.sender && relayData.exclusivityDeadline >= getCurrentTime()) {
            revert NotExclusiveRelayer();
        }

        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: _getV3RelayHash(relayData),
            updatedOutputAmount: updatedOutputAmount,
            updatedRecipient: updatedRecipient,
            updatedMessage: updatedMessage,
            repaymentChainId: repaymentChainId
        });

        _verifyUpdateV3DepositMessage(
            relayData.depositor,
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            depositorSignature
        );

        _fillRelayV3(relayExecution, msg.sender, false);
    }

    /**
     * @notice Request Across to send LP funds to this contract to fulfill a slow fill relay
     * for a deposit in the next bundle.
     * @dev Slow fills are not possible unless the input and output tokens are "equivalent", i.e.
     * they route to the same L1 token via PoolRebalanceRoutes.
     * @dev Slow fills are created by inserting slow fill objects into a merkle tree that is included
     * in the next HubPool "root bundle". Once the optimistic challenge window has passed, the HubPool
     * will relay the slow root to this chain via relayRootBundle(). Once the slow root is relayed,
     * the slow fill can be executed by anyone who calls executeV3SlowRelayLeaf().
     * @dev Cannot request a slow fill if the fill deadline has passed.
     * @dev Cannot request a slow fill if the relay has already been filled or a slow fill has already been requested.
     * @param relayData struct containing all the data needed to identify the deposit that should be
     * slow filled. If any of the params are missing or different from the origin chain deposit,
     * then Across will not include a slow fill for the intended deposit.
     */
    function requestV3SlowFill(V3RelayData calldata relayData) public override nonReentrant unpausedFills {
        if (relayData.fillDeadline < getCurrentTime()) revert ExpiredFillDeadline();

        bytes32 relayHash = _getV3RelayHash(relayData);
        if (fillStatuses[relayHash] != uint256(FillStatus.Unfilled)) revert InvalidSlowFillRequest();
        fillStatuses[relayHash] = uint256(FillStatus.RequestedSlowFill);

        emit RequestedV3SlowFill(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayData.depositor,
            relayData.recipient,
            relayData.message
        );
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
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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
    ) public override nonReentrant {
        _preExecuteLeafHook(destinationToken);
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
     * @notice Executes a slow relay leaf stored as part of a root bundle relayed by the HubPool.
     * @dev Executing a slow fill leaf is equivalent to filling the relayData so this function cannot be used to
     * double fill a recipient. The relayData that is filled is included in the slowFillLeaf and is hashed
     * like any other fill sent through fillV3Relay().
     * @dev There is no relayer credited with filling this relay since funds are sent directly out of this contract.
     * @param slowFillLeaf Contains all data necessary to uniquely identify a relay for this chain. This struct is
     * hashed and included in a merkle root that is relayed to all spoke pools.
     * - relayData: struct containing all the data needed to identify the original deposit to be slow filled.
     * - chainId: chain identifier where slow fill leaf should be executed. If this doesn't match this chain's
     * chainId, then this function will revert.
     * - updatedOutputAmount: Amount to be sent to recipient out of this contract's balance. Can be set differently
     * from relayData.outputAmount to charge a different fee because this deposit was "slow" filled. Usually,
     * this will be set higher to reimburse the recipient for waiting for the slow fill.
     * @param rootBundleId Unique ID of root bundle containing slow relay root that this leaf is contained in.
     * @param proof Inclusion proof for this leaf in slow relay root in root bundle.
     */
    function executeV3SlowRelayLeaf(
        V3SlowFill calldata slowFillLeaf,
        uint32 rootBundleId,
        bytes32[] calldata proof
    ) public override nonReentrant {
        V3RelayData memory relayData = slowFillLeaf.relayData;

        _preExecuteLeafHook(relayData.outputToken);

        // @TODO In the future consider allowing way for slow fill leaf to be created with updated
        // deposit params like outputAmount, message and recipient.
        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: _getV3RelayHash(relayData),
            updatedOutputAmount: slowFillLeaf.updatedOutputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: 0 // Hardcoded to 0 for slow fills
        });

        _verifyV3SlowFill(relayExecution, rootBundleId, proof);

        // - 0x0 hardcoded as relayer for slow fill execution.
        _fillRelayV3(relayExecution, address(0), true);
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
    ) public payable virtual override nonReentrant {
        _preExecuteLeafHook(relayerRefundLeaf.l2TokenAddress);

        if (relayerRefundLeaf.chainId != chainId()) revert InvalidChainId();

        RootBundle storage rootBundle = rootBundles[rootBundleId];

        // Check that proof proves that relayerRefundLeaf is contained within the relayer refund root.
        // Note: This should revert if the relayerRefundRoot is uninitialized.
        if (!MerkleLib.verifyRelayerRefund(rootBundle.relayerRefundRoot, relayerRefundLeaf, proof))
            revert InvalidMerkleProof();

        _setClaimedLeaf(rootBundleId, relayerRefundLeaf.leafId);

        _distributeRelayerRefunds(
            relayerRefundLeaf.chainId,
            relayerRefundLeaf.amountToReturn,
            relayerRefundLeaf.refundAmounts,
            relayerRefundLeaf.leafId,
            relayerRefundLeaf.l2TokenAddress,
            relayerRefundLeaf.refundAddresses
        );

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

    /**
     * @notice Executes a relayer refund leaf stored as part of a root bundle relayed by the HubPool. Sends
     * to relayers their amount refunded by the system for successfully filling relays.
     * @param relayerRefundLeaf Contains all data necessary to uniquely identify refunds for this chain. This struct is
     * hashed and included in a merkle root that is relayed to all spoke pools. See V3RelayerRefundLeaf struct
     * for more detailed comments.
     * - amountToReturn: amount of tokens to return to HubPool out of this contract.
     * - refundAmounts: array of amounts to refund to relayers.
     * - refundAddresses: array of relayer addresses to refund
     * - relayData: struct containing all the data needed to identify the original deposit to be slow filled.
     * - chainId: chain identifier where relayer refund leaf should be executed. If this doesn't match this chain's
     * chainId, then this function will revert.
     * - leafId: index of this leaf within the merkle root, used to track whether this leaf has been executed.
     * - fillsRefundedRoot: Merkle root of all successful fills refunded by this leaf. Can be used by third parties
     * to track which fills were successful.
     * - fillsRefundedHash: Unique identifier where anyone can find the full fills refunded tree.
     * @param rootBundleId Unique ID of root bundle containing relayer refund root that this leaf is contained in.
     * @param proof Inclusion proof for this leaf in relayer refund root in root bundle.
     */

    function executeV3RelayerRefundLeaf(
        uint32 rootBundleId,
        V3SpokePoolInterface.V3RelayerRefundLeaf calldata relayerRefundLeaf,
        bytes32[] calldata proof
    ) public payable virtual override nonReentrant {
        _preExecuteLeafHook(relayerRefundLeaf.l2TokenAddress);

        if (relayerRefundLeaf.chainId != chainId()) revert InvalidChainId();

        RootBundle storage rootBundle = rootBundles[rootBundleId];

        // Check that proof proves that relayerRefundLeaf is contained within the relayer refund root.
        // Note: This should revert if the relayerRefundRoot is uninitialized.
        if (!MerkleLib.verifyV3RelayerRefund(rootBundle.relayerRefundRoot, relayerRefundLeaf, proof))
            revert InvalidMerkleProof();
        _setClaimedLeaf(rootBundleId, relayerRefundLeaf.leafId);

        _distributeRelayerRefunds(
            relayerRefundLeaf.chainId,
            relayerRefundLeaf.amountToReturn,
            relayerRefundLeaf.refundAmounts,
            relayerRefundLeaf.leafId,
            relayerRefundLeaf.l2TokenAddress,
            relayerRefundLeaf.refundAddresses
        );

        emit ExecutedV3RelayerRefundRoot(
            relayerRefundLeaf.amountToReturn,
            relayerRefundLeaf.refundAmounts,
            rootBundleId,
            relayerRefundLeaf.leafId,
            relayerRefundLeaf.l2TokenAddress,
            relayerRefundLeaf.refundAddresses,
            relayerRefundLeaf.fillsRefundedRoot,
            relayerRefundLeaf.fillsRefundedHash
        );
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

    function _deposit(
        address depositor,
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        int64 relayerFeePct,
        uint32 quoteTimestamp,
        bytes memory message
    ) internal {
        // Check that deposit route is enabled.
        require(enabledDepositRoutes[originToken][destinationChainId], "Disabled route");

        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(SignedMath.abs(relayerFeePct) < 0.5e18, "Invalid relayer fee");
        require(amount <= MAX_TRANSFER_SIZE, "Amount too large");

        // Require that quoteTimestamp has a maximum age so that depositors pay an LP fee based on recent HubPool usage.
        // It is assumed that cross-chain timestamps are normally loosely in-sync, but clock drift can occur. If the
        // SpokePool time stalls or lags significantly, it is still possible to make deposits by setting quoteTimestamp
        // within the configured buffer. The owner should pause deposits if this is undesirable. This will underflow if
        // quoteTimestamp is more than depositQuoteTimeBuffer; this is safe but will throw an unintuitive error.

        // slither-disable-next-line timestamp
        require(getCurrentTime() - quoteTimestamp <= depositQuoteTimeBuffer, "invalid quoteTimestamp");

        // Increment count of deposits so that deposit ID for this spoke pool is unique.
        uint32 newDepositId = numberOfDeposits++;

        // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // transaction then the user is sending ETH. In this case, the ETH should be deposited to wrappedNativeToken.
        if (originToken == address(wrappedNativeToken) && msg.value > 0) {
            require(msg.value == amount, "msg.value must match amount");
            wrappedNativeToken.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the user's wallet as per normal.
            // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them.
            // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else IERC20Upgradeable(originToken).safeTransferFrom(msg.sender, address(this), amount);

        emit V3FundsDeposited(
            originToken, // inputToken
            address(0), // outputToken
            // - setting token to 0x0 will signal to off-chain validator that the "equivalent"
            // token as the inputToken for the destination chain should be replaced here.
            amount, // inputAmount
            _computeAmountPostFees(amount, relayerFeePct), // outputAmount
            // - output amount will be the deposit amount less relayerFeePct, which should now be set
            // equal to realizedLpFeePct + gasFeePct + capitalCostFeePct where (gasFeePct + capitalCostFeePct)
            // is equal to the old usage of `relayerFeePct`.
            destinationChainId,
            newDepositId,
            quoteTimestamp,
            type(uint32).max, // fillDeadline. Older deposits don't expire.
            0, // exclusivityDeadline.
            depositor,
            recipient,
            address(0), // exclusiveRelayer. Setting this to 0x0 will signal to off-chain validator that there
            // is no exclusive relayer.
            message
        );
    }

    function _distributeRelayerRefunds(
        uint256 _chainId,
        uint256 amountToReturn,
        uint256[] memory refundAmounts,
        uint32 leafId,
        address l2TokenAddress,
        address[] memory refundAddresses
    ) internal {
        if (refundAddresses.length != refundAmounts.length) revert InvalidMerkleLeaf();

        // Send each relayer refund address the associated refundAmount for the L2 token address.
        // Note: Even if the L2 token is not enabled on this spoke pool, we should still refund relayers.
        uint256 length = refundAmounts.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 amount = refundAmounts[i];
            if (amount > 0) IERC20Upgradeable(l2TokenAddress).safeTransfer(refundAddresses[i], amount);
        }

        // If leaf's amountToReturn is positive, then send L2 --> L1 message to bridge tokens back via
        // chain-specific bridging method.
        if (amountToReturn > 0) {
            _bridgeTokensToHubPool(amountToReturn, l2TokenAddress);

            emit TokensBridged(amountToReturn, _chainId, leafId, l2TokenAddress, msg.sender);
        }
    }

    // Verifies inclusion proof of leaf in root and sends recipient remainder of relay. Marks relay as filled.
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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
            maxTokensToSend: SLOW_FILL_MAX_TOKENS_TO_SEND,
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

    function _preExecuteLeafHook(address) internal virtual {
        // This method by default is a no-op. Different child spoke pools might want to execute functionality here
        // such as wrapping any native tokens owned by the contract into wrapped tokens before proceeding with
        // executing the leaf.
    }

    // Should be overriden by implementing contract depending on how L2 handles sending tokens to L1.
    function _bridgeTokensToHubPool(uint256 amountToReturn, address l2TokenAddress) internal virtual;

    function _setClaimedLeaf(uint32 rootBundleId, uint32 leafId) internal {
        RootBundle storage rootBundle = rootBundles[rootBundleId];

        // Verify the leafId in the leaf has not yet been claimed.
        if (MerkleLib.isClaimed(rootBundle.claimedBitmap, leafId)) revert ClaimedMerkleLeaf();

        // Set leaf as claimed in bitmap. This is passed by reference to the storage rootBundle.
        MerkleLib.setClaimed(rootBundle.claimedBitmap, leafId);
    }

    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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

    function _verifyUpdateV3DepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
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
                    UPDATE_V3_DEPOSIT_DETAILS_HASH,
                    depositId,
                    originChainId,
                    updatedOutputAmount,
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

    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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

    function _verifyV3SlowFill(
        V3RelayExecutionParams memory relayExecution,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) internal view {
        V3SlowFill memory slowFill = V3SlowFill({
            relayData: relayExecution.relay,
            chainId: chainId(),
            updatedOutputAmount: relayExecution.updatedOutputAmount
        });

        if (!MerkleLib.verifyV3SlowRelayFulfillment(rootBundles[rootBundleId].slowRelayRoot, slowFill, proof))
            revert InvalidMerkleProof();
    }

    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function _computeAmountPreFees(uint256 amount, int64 feesPct) private pure returns (uint256) {
        return (1e18 * amount) / uint256((int256(1e18) - feesPct));
    }

    function _computeAmountPostFees(uint256 amount, int256 feesPct) private pure returns (uint256) {
        return (amount * uint256(int256(1e18) - feesPct)) / 1e18;
    }

    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
    function _getRelayHash(SpokePoolInterface.RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(relayData));
    }

    function _getV3RelayHash(V3RelayData memory relayData) private view returns (bytes32) {
        return keccak256(abi.encode(relayData, chainId()));
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends wrappedNativeToken.
    function _unwrapwrappedNativeTokenTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20Upgradeable(address(wrappedNativeToken)).safeTransfer(to, amount);
        } else {
            wrappedNativeToken.withdraw(amount);
            AddressLibUpgradeable.sendValue(to, amount);
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
    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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
        require(DEPRECATED_relayFills[relayExecution.relayHash] < relayData.amount, "relay filled");

        // Derive the amount of the relay filled if the caller wants to send exactly maxTokensToSend tokens to
        // the recipient. For example, if the user wants to send 10 tokens to the recipient, the full relay amount
        // is 100, and the fee %'s total 5%, then this computation would return ~10.5, meaning that to fill 10.5/100
        // of the full relay size, the caller would need to send 10 tokens to the user.
        // This is equivalent to the amount to be sent by the relayer before fees have been taken out.
        fillAmountPreFees = _computeAmountPreFees(
            relayExecution.maxTokensToSend,
            (relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct)
        );
        // If fill amount minus fees, which is possible with small fill amounts and negative fees, then
        // revert.
        require(fillAmountPreFees > 0, "fill amount pre fees is 0");

        // If user's specified max amount to send is greater than the amount of the relay remaining pre-fees,
        // we'll pull exactly enough tokens to complete the relay.
        uint256 amountRemainingInRelay = relayData.amount - DEPRECATED_relayFills[relayExecution.relayHash];
        if (amountRemainingInRelay < fillAmountPreFees) {
            fillAmountPreFees = amountRemainingInRelay;
        }

        // Apply post-fees computation to amount that relayer will send to user. Rounding errors are possible
        // when computing fillAmountPreFees and then amountToSend, and we just want to enforce that
        // the error added to amountToSend is consistently applied to partial and full fills.
        uint256 amountToSend = _computeAmountPostFees(
            fillAmountPreFees,
            relayData.realizedLpFeePct + relayExecution.updatedRelayerFeePct
        );

        // This can only happen in a slow fill, where the contract is funding the relay.
        if (relayExecution.payoutAdjustmentPct != 0) {
            // If payoutAdjustmentPct is positive, then the recipient will receive more than the amount they
            // were originally expecting. If it is negative, then the recipient will receive less.
            // -1e18 is -100%. Because we cannot pay out negative values, that is the minimum.
            require(relayExecution.payoutAdjustmentPct >= -1e18, "payoutAdjustmentPct too small");

            // Allow the payout adjustment to go up to 1000% (i.e. 11x).
            // This is a sanity check to ensure the payouts do not grow too large via some sort of issue in bundle
            // construction.
            require(relayExecution.payoutAdjustmentPct <= 100e18, "payoutAdjustmentPct too large");

            // Note: since _computeAmountPostFees is typically intended for fees, the signage must be reversed.
            amountToSend = _computeAmountPostFees(amountToSend, -relayExecution.payoutAdjustmentPct);

            // Note: this error should never happen, since the maxTokensToSend is expected to be set much higher than
            // the amount, but it is here as a sanity check.
            require(amountToSend <= relayExecution.maxTokensToSend, "Somehow hit maxTokensToSend!");
        }

        // Since the first partial fill is used to update the fill counter for the entire refund amount, we don't have
        // a simple way to handle the case where follow-up partial fills take repayment on different chains. We'd
        // need a way to decrement the fill counter in this case (or increase deposit counter) to ensure that users
        // have adequate frontrunning protections.
        // Instead of adding complexity, we require that all partial fills set repayment chain equal to destination chain.
        // Note: .slowFill is checked because slow fills set repaymentChainId to 0.
        bool localRepayment = relayExecution.repaymentChainId == relayExecution.relay.destinationChainId;
        require(
            localRepayment || relayExecution.relay.amount == fillAmountPreFees || relayExecution.slowFill,
            "invalid repayment chain"
        );

        // relayFills keeps track of pre-fee fill amounts as a convenience to relayers who want to specify round
        // numbers for the maxTokensToSend parameter or convenient numbers like 100 (i.e. relayers who will fully
        // fill any relay up to 100 tokens, and partial fill with 100 tokens for larger relays).
        DEPRECATED_relayFills[relayExecution.relayHash] += fillAmountPreFees;

        // If relayer and receiver are the same address, there is no need to do any transfer, as it would result in no
        // net movement of funds.
        // Note: this is important because it means that relayers can intentionally self-relay in a capital efficient
        // way (no need to have funds on the destination).
        // If this is a slow fill, we can't exit early since we still need to send funds out of this contract
        // since there is no "relayer".
        if (msg.sender == relayExecution.updatedRecipient && !relayExecution.slowFill) return fillAmountPreFees;

        // If relay token is wrappedNativeToken then unwrap and send native token.
        if (relayData.destinationToken == address(wrappedNativeToken)) {
            // Note: useContractFunds is True if we want to send funds to the recipient directly out of this contract,
            // otherwise we expect the caller to send funds to the recipient. If useContractFunds is True and the
            // recipient wants wrappedNativeToken, then we can assume that wrappedNativeToken is already in the
            // contract, otherwise we'll need the user to send wrappedNativeToken to this contract. Regardless, we'll
            // need to unwrap it to native token before sending to the user.
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapwrappedNativeTokenTo(payable(relayExecution.updatedRecipient), amountToSend);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else {
            // Note: Similar to note above, send token directly from the contract to the user in the slow relay case.
            if (!relayExecution.slowFill)
                IERC20Upgradeable(relayData.destinationToken).safeTransferFrom(
                    msg.sender,
                    relayExecution.updatedRecipient,
                    amountToSend
                );
            else
                IERC20Upgradeable(relayData.destinationToken).safeTransfer(
                    relayExecution.updatedRecipient,
                    amountToSend
                );
        }

        if (relayExecution.updatedRecipient.isContract() && relayExecution.updatedMessage.length > 0) {
            _preHandleMessageHook();
            AcrossMessageHandler(relayExecution.updatedRecipient).handleAcrossMessage(
                relayData.destinationToken,
                amountToSend,
                DEPRECATED_relayFills[relayExecution.relayHash] >= relayData.amount,
                msg.sender,
                relayExecution.updatedMessage
            );
        }
    }

    function _preHandleMessageHook() internal virtual {
        // This method by default is a no-op.
    }

    // @param relayer: relayer who is actually credited as filling this deposit. Can be different from
    // exclusiveRelayer if passed exclusivityDeadline or if slow fill.
    function _fillRelayV3(
        V3RelayExecutionParams memory relayExecution,
        address relayer,
        bool isSlowFill
    ) internal {
        V3RelayData memory relayData = relayExecution.relay;

        if (relayData.fillDeadline < getCurrentTime()) revert ExpiredFillDeadline();

        bytes32 relayHash = relayExecution.relayHash;

        // If a slow fill for this fill was requested then the relayFills value for this hash will be
        // FillStatus.RequestedSlowFill. Therefore, if this is the status, then this fast fill
        // will be replacing the slow fill. If this is a slow fill execution, then the following variable
        // is trivially true. We'll emit this value in the FilledRelay
        // event to assist the Dataworker in knowing when to return funds back to the HubPool that can no longer
        // be used for a slow fill execution.
        FillType fillType = isSlowFill
            ? FillType.SlowFill
            : (
                // The following is true if this is a fast fill that was sent after a slow fill request.
                fillStatuses[relayExecution.relayHash] == uint256(FillStatus.RequestedSlowFill)
                    ? FillType.ReplacedSlowFill
                    : FillType.FastFill
            );

        // @dev This function doesn't support partial fills. Therefore, we associate the relay hash with
        // an enum tracking its fill status. All filled relays, whether slow or fast fills, are set to the Filled
        // status. However, we also use this slot to track whether this fill had a slow fill requested. Therefore
        // we can include a bool in the FilledRelay event making it easy for the dataworker to compute if this
        // fill was a fast fill that replaced a slow fill and therefore this SpokePool has excess funds that it
        // needs to send back to the HubPool.
        if (fillStatuses[relayHash] == uint256(FillStatus.Filled)) revert RelayFilled();
        fillStatuses[relayHash] = uint256(FillStatus.Filled);

        // @dev Before returning early, emit events to assist the dataworker in being able to know which fills were
        // successful.
        emit FilledV3Relay(
            relayData.inputToken,
            relayData.outputToken,
            relayData.inputAmount,
            relayData.outputAmount,
            relayExecution.repaymentChainId,
            relayData.originChainId,
            relayData.depositId,
            relayData.fillDeadline,
            relayData.exclusivityDeadline,
            relayData.exclusiveRelayer,
            relayer,
            relayData.depositor,
            relayData.recipient,
            relayData.message,
            V3RelayExecutionEventInfo({
                updatedRecipient: relayExecution.updatedRecipient,
                updatedMessage: relayExecution.updatedMessage,
                updatedOutputAmount: relayExecution.updatedOutputAmount,
                fillType: fillType
            })
        );

        // If relayer and receiver are the same address, there is no need to do any transfer, as it would result in no
        // net movement of funds.
        // Note: this is important because it means that relayers can intentionally self-relay in a capital efficient
        // way (no need to have funds on the destination).
        // If this is a slow fill, we can't exit early since we still need to send funds out of this contract
        // since there is no "relayer".
        address recipientToSend = relayExecution.updatedRecipient;

        if (msg.sender == recipientToSend && !isSlowFill) return;

        // If relay token is wrappedNativeToken then unwrap and send native token.
        address outputToken = relayData.outputToken;
        uint256 amountToSend = relayExecution.updatedOutputAmount;
        if (outputToken == address(wrappedNativeToken)) {
            // Note: useContractFunds is True if we want to send funds to the recipient directly out of this contract,
            // otherwise we expect the caller to send funds to the recipient. If useContractFunds is True and the
            // recipient wants wrappedNativeToken, then we can assume that wrappedNativeToken is already in the
            // contract, otherwise we'll need the user to send wrappedNativeToken to this contract. Regardless, we'll
            // need to unwrap it to native token before sending to the user.
            if (!isSlowFill) IERC20Upgradeable(outputToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapwrappedNativeTokenTo(payable(recipientToSend), amountToSend);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else {
            // Note: Similar to note above, send token directly from the contract to the user in the slow relay case.
            if (!isSlowFill) IERC20Upgradeable(outputToken).safeTransferFrom(msg.sender, recipientToSend, amountToSend);
            else IERC20Upgradeable(outputToken).safeTransfer(recipientToSend, amountToSend);
        }

        bytes memory updatedMessage = relayExecution.updatedMessage;
        if (recipientToSend.isContract() && updatedMessage.length > 0) {
            _preHandleMessageHook();
            AcrossMessageHandler(recipientToSend).handleV3AcrossMessage(
                outputToken,
                amountToSend,
                msg.sender,
                updatedMessage
            );
        }
    }

    /// @custom:audit FOLLOWING FUNCTION TO BE DEPRECATED
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
            DEPRECATED_relayFills[relayExecution.relayHash],
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

    // Implementing contract needs to override this to ensure that only the appropriate cross chain admin can execute
    // certain admin functions. For L2 contracts, the cross chain admin refers to some L1 address or contract, and for
    // L1, this would just be the same admin of the HubPool.
    function _requireAdminSender() internal virtual;

    // Added to enable the this contract to receive native token (ETH). Used when unwrapping wrappedNativeToken.
    receive() external payable {}

    // Reserve storage slots for future versions of this base contract to add state variables without
    // affecting the storage layout of child contracts. Decrement the size of __gap whenever state variables
    // are added. This is at bottom of contract to make sure it's always at the end of storage.
    uint256[999] private __gap;
}
