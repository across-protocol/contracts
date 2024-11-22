// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./erc7683/ERC7683.sol";
import "./erc7683/ERC7683Permit2Lib.sol";
import "./external/interfaces/WETH9Interface.sol";
import "./interfaces/SpokePoolMessageHandler.sol";
import "./interfaces/SpokePoolInterface.sol";
import "./interfaces/V3SpokePoolInterface.sol";
import "./upgradeable/MultiCallerUpgradeable.sol";
import "./upgradeable/EIP712CrossChainUpgradeable.sol";
import "./upgradeable/AddressLibUpgradeable.sol";
import "./libraries/AddressConverters.sol";

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

/**
 * @title SpokePool
 * @notice Base contract deployed on source and destination chains enabling depositors to transfer assets from source to
 * destination. Deposit orders are fulfilled by off-chain relayers who also interact with this contract. Deposited
 * tokens are locked on the source chain and relayers send the recipient the desired token currency and amount
 * on the destination chain. Locked source chain tokens are later sent over the canonical token bridge to L1 HubPool.
 * Relayers are refunded with destination tokens out of this contract after another off-chain actor, a "data worker",
 * submits a proof that the relayer correctly submitted a relay on this SpokePool.
 * @custom:security-contact bugs@across.to
 */
abstract contract SpokePool is
    V3SpokePoolInterface,
    SpokePoolInterface,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    MultiCallerUpgradeable,
    EIP712CrossChainUpgradeable,
    IDestinationSettler
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressLibUpgradeable for address;
    using Bytes32ToAddress for bytes32;
    using AddressToBytes32 for address;

    // Address of the L1 contract that acts as the owner of this SpokePool. This should normally be set to the HubPool
    // address. The crossDomainAdmin address is unused when the SpokePool is deployed to the same chain as the HubPool.
    address public crossDomainAdmin;

    // Address of the L1 contract that will send tokens to and receive tokens from this contract to fund relayer
    // refunds and slow relays.
    address public withdrawalRecipient;

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

    // Mapping of L2TokenAddress to relayer to outstanding refund amount. Used when a relayer repayment fails for some
    // reason (eg blacklist) to track their outstanding liability, thereby letting them claim it later.
    mapping(address => mapping(address => uint256)) public relayerRefund;

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

    bytes32 public constant UPDATE_V3_DEPOSIT_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,uint256 updatedOutputAmount,bytes32 updatedRecipient,bytes updatedMessage)"
        );

    bytes32 public constant UPDATE_V3_DEPOSIT_ADDRESS_OVERLOAD_DETAILS_HASH =
        keccak256(
            "UpdateDepositDetails(uint32 depositId,uint256 originChainId,uint256 updatedOutputAmount,address updatedRecipient,bytes updatedMessage)"
        );

    // Default chain Id used to signify that no repayment is requested, for example when executing a slow fill.
    uint256 public constant EMPTY_REPAYMENT_CHAIN_ID = 0;
    // Default address used to signify that no relayer should be credited with a refund, for example
    // when executing a slow fill.
    bytes32 public constant EMPTY_RELAYER = bytes32(0);
    // This is the magic value that signals to the off-chain validator
    // that this deposit can never expire. A deposit with this fill deadline should always be eligible for a
    // slow fill, meaning that its output token and input token must be "equivalent". Therefore, this value is only
    // used as a fillDeadline in deposit(), a soon to be deprecated function that also hardcodes outputToken to
    // the zero address, which forces the off-chain validator to replace the output token with the equivalent
    // token for the input token. By using this magic value, off-chain validators do not have to keep
    // this event in their lookback window when querying for expired deposits.
    uint32 public constant INFINITE_FILL_DEADLINE = type(uint32).max;

    // One year in seconds. If `exclusivityParameter` is set to a value less than this, then the emitted
    // exclusivityDeadline in a deposit event will be set to the current time plus this value.
    uint32 public constant MAX_EXCLUSIVITY_PERIOD_SECONDS = 31_536_000;
    /****************************************
     *                EVENTS                *
     ****************************************/
    event SetXDomainAdmin(address indexed newAdmin);
    event SetWithdrawalRecipient(address indexed newWithdrawalRecipient);
    event EnabledDepositRoute(address indexed originToken, uint256 indexed destinationChainId, bool enabled);
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
        bool deferredRefunds,
        address caller
    );
    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        bytes32 indexed l2TokenAddress,
        address caller
    );
    event EmergencyDeleteRootBundle(uint256 indexed rootBundleId);
    event PausedDeposits(bool isPaused);
    event PausedFills(bool isPaused);

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
     * @param _withdrawalRecipient Address which receives token withdrawals. Can be changed by admin. For Spoke Pools on L2, this will
     * likely be the hub pool.
     */
    function __SpokePool_init(
        uint32 _initialDepositId,
        address _crossDomainAdmin,
        address _withdrawalRecipient
    ) public onlyInitializing {
        numberOfDeposits = _initialDepositId;
        __EIP712_init("ACROSS-V2", "1.0.0");
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        _setCrossDomainAdmin(_crossDomainAdmin);
        _setWithdrawalRecipient(_withdrawalRecipient);
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
        if (pausedDeposits) revert DepositsArePaused();
        _;
    }

    modifier unpausedFills() {
        if (pausedFills) revert FillsArePaused();
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
     * @dev Affects `deposit()` but not `speedUpV3Deposit()`, so that existing deposits can be sped up and still
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
     * @notice Change L1 withdrawal recipient address. Callable by admin only.
     * @param newWithdrawalRecipient New withdrawal recipient address.
     */
    function setWithdrawalRecipient(address newWithdrawalRecipient) public override onlyAdmin nonReentrant {
        _setWithdrawalRecipient(newWithdrawalRecipient);
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
     *    LEGACY DEPOSITOR FUNCTIONS      *
     **************************************/

    /**
     * @notice Called by user to bridge funds from origin to destination chain. Depositor will effectively lock
     * tokens in this contract and receive a destination token on the destination chain. The origin => destination
     * token mapping is stored on the L1 HubPool.
     * @notice The caller must first approve this contract to spend amount of originToken.
     * @notice The originToken => destinationChainId must be enabled.
     * @notice This method is payable because the caller is able to deposit native token if the originToken is
     * wrappedNativeToken and this function will handle wrapping the native token to wrappedNativeToken.
     * @dev Produces a V3FundsDeposited event with an infinite expiry, meaning that this deposit can never expire.
     * Moreover, the event's outputToken is set to 0x0 meaning that this deposit can always be slow filled.
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

    /********************************************
     *            DEPOSITOR FUNCTIONS           *
     ********************************************/

    /**
     * @notice Previously, this function allowed the caller to specify the exclusivityDeadline, otherwise known as the
     * as exact timestamp on the destination chain before which only the exclusiveRelayer could fill the deposit. Now,
     * the caller is expected to pass in a number that will be interpreted either as an offset or a fixed
     * timestamp depending on its value.
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
     * challenge window in the HubPool, less a system fee.
     * @param outputAmount The amount of output tokens that the relayer will send to the recipient on the destination.
     * @param destinationChainId The destination chain identifier. Must be enabled along with the input token
     * as a valid deposit route from this spoke pool or this transaction will revert.
     * @param exclusiveRelayer The relayer that will be exclusively allowed to fill this deposit before the
     * exclusivity deadline timestamp. This must be a valid, non-zero address if the exclusivity deadline is
     * greater than the current block.timestamp. If the exclusivity deadline is < currentTime, then this must be
     * address(0), and vice versa if this is address(0).
     * @param quoteTimestamp The HubPool timestamp that is used to determine the system fee paid by the depositor.
     *  This must be set to some time between [currentTime - depositQuoteTimeBuffer, currentTime]
     * where currentTime is block.timestamp on this chain or this transaction will revert.
     * @param fillDeadline The deadline for the relayer to fill the deposit. After this destination chain timestamp,
     * the fill will revert on the destination chain. Must be set between [currentTime, currentTime + fillDeadlineBuffer]
     * where currentTime is block.timestamp on this chain or this transaction will revert.
     * @param exclusivityParameter This value is used to set the exclusivity deadline timestamp in the emitted deposit
     * event. Before this destinationchain timestamp, only the exclusiveRelayer (if set to a non-zero address),
     * can fill this deposit. There are three ways to use this parameter:
     *     1. NO EXCLUSIVITY: If this value is set to 0, then a timestamp of 0 will be emitted,
     *        meaning that there is no exclusivity period.
     *     2. OFFSET: If this value is less than MAX_EXCLUSIVITY_PERIOD_SECONDS, then add this value to
     *        the block.timestamp to derive the exclusive relayer deadline. Note that using the parameter in this way
     *        will expose the filler of the deposit to the risk that the block.timestamp of this event gets changed
     *        due to a chain-reorg, which would also change the exclusivity timestamp.
     *     3. TIMESTAMP: Otherwise, set this value as the exclusivity deadline timestamp.
     * which is the deadline for the exclusiveRelayer to fill the deposit.
     * @param message The message to send to the recipient on the destination chain if the recipient is a contract.
     * If the message is not empty, the recipient contract must implement handleV3AcrossMessage() or the fill will revert.
     */
    function depositV3(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) public payable override nonReentrant unpausedDeposits {
        _depositV3(
            depositor,
            recipient,
            inputToken.toAddress(), // Input token will always be an address when deposits originate from EVM.
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            numberOfDeposits++, // Increment count of deposits so that deposit ID for this spoke pool is unique.
            quoteTimestamp,
            fillDeadline,
            exclusivityParameter,
            message
        );
    }

    /**
     * @notice An overloaded version of `depositV3` that accepts `address` types for backward compatibility.
     * This function allows bridging of input tokens cross-chain to a destination chain, receiving a specified amount of output tokens.
     * The relayer is refunded in input tokens on a repayment chain of their choice, minus system fees, after an optimistic challenge
     * window. The exclusivity period is specified as an offset from the current block timestamp.
     *
     * @dev This version mirrors the original `depositV3` function, but uses `address` types for `depositor`, `recipient`,
     * `inputToken`, `outputToken`, and `exclusiveRelayer` for compatibility with contracts using the `address` type.
     *
     * The key functionality and logic remain identical, ensuring interoperability across both versions.
     *
     * @param depositor The account credited with the deposit who can request to "speed up" this deposit by modifying
     * the output amount, recipient, and message.
     * @param recipient The account receiving funds on the destination chain. Can be an EOA or a contract. If
     * the output token is the wrapped native token for the chain, then the recipient will receive native token if
     * an EOA or wrapped native token if a contract.
     * @param inputToken The token pulled from the caller's account and locked into this contract to initiate the deposit.
     * The equivalent of this token on the relayer's repayment chain of choice will be sent as a refund. If this is equal
     * to the wrapped native token, the caller can optionally pass in native token as msg.value, provided msg.value = inputTokenAmount.
     * @param outputToken The token that the relayer will send to the recipient on the destination chain. Must be an ERC20.
     * @param inputAmount The amount of input tokens pulled from the caller's account and locked into this contract. This
     * amount will be sent to the relayer as a refund following an optimistic challenge window in the HubPool, less a system fee.
     * @param outputAmount The amount of output tokens that the relayer will send to the recipient on the destination.
     * @param destinationChainId The destination chain identifier. Must be enabled along with the input token as a valid
     * deposit route from this spoke pool or this transaction will revert.
     * @param exclusiveRelayer The relayer exclusively allowed to fill this deposit before the exclusivity deadline.
     * @param quoteTimestamp The HubPool timestamp that determines the system fee paid by the depositor. This must be set
     * between [currentTime - depositQuoteTimeBuffer, currentTime] where currentTime is block.timestamp on this chain.
     * @param fillDeadline The deadline for the relayer to fill the deposit. After this destination chain timestamp, the fill will
     * revert on the destination chain. Must be set between [currentTime, currentTime + fillDeadlineBuffer] where currentTime
     * is block.timestamp on this chain.
     * @param exclusivityPeriod Added to the current time to set the exclusive relayer deadline. After this timestamp,
     * anyone can fill the deposit.
     * @param message The message to send to the recipient on the destination chain if the recipient is a contract. If the
     * message is not empty, the recipient contract must implement `handleV3AcrossMessage()` or the fill will revert.
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
        uint32 exclusivityPeriod,
        bytes calldata message
    ) public payable {
        depositV3(
            depositor.toBytes32(),
            recipient.toBytes32(),
            inputToken.toBytes32(),
            outputToken.toBytes32(),
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer.toBytes32(),
            quoteTimestamp,
            fillDeadline,
            exclusivityPeriod,
            message
        );
    }

    /**
     * @notice Submits deposit and sets quoteTimestamp to current Time. Sets fill and exclusivity
     * deadlines as offsets added to the current time. This function is designed to be called by users
     * such as Multisig contracts who do not have certainty when their transaction will mine.
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
     * @param fillDeadlineOffset Added to the current time to set the fill deadline, which is the deadline for the
     * relayer to fill the deposit. After this destination chain timestamp, the fill will revert on the
     * destination chain.
     * @param exclusivityPeriod Added to the current time to set the exclusive relayer deadline,
     * which is the deadline for the exclusiveRelayer to fill the deposit. After this destination chain timestamp,
     * anyone can fill the deposit up to the fillDeadline timestamp.
     * @param message The message to send to the recipient on the destination chain if the recipient is a contract.
     * If the message is not empty, the recipient contract must implement handleV3AcrossMessage() or the fill will revert.
     */
    function depositV3Now(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 fillDeadlineOffset,
        uint32 exclusivityPeriod,
        bytes calldata message
    ) external payable {
        depositV3(
            depositor,
            recipient,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            uint32(getCurrentTime()),
            uint32(getCurrentTime()) + fillDeadlineOffset,
            exclusivityPeriod,
            message
        );
    }

    /**
     * @notice An overloaded version of `depositV3Now` that supports addresses as input types for backward compatibility.
     * This function submits a deposit and sets `quoteTimestamp` to the current time. The `fill` and `exclusivity` deadlines
     * are set as offsets added to the current time. It is designed to be called by users, including Multisig contracts, who may
     * not have certainty when their transaction will be mined.
     *
     * @dev This version is identical to the original `depositV3Now` but uses `address` types for `depositor`, `recipient`,
     * `inputToken`, `outputToken`, and `exclusiveRelayer` to support compatibility with older systems.
     * It maintains the same logic and purpose, ensuring interoperability with both versions.
     *
     * @param depositor The account credited with the deposit, who can request to "speed up" this deposit by modifying
     * the output amount, recipient, and message.
     * @param recipient The account receiving funds on the destination chain. Can be an EOA or a contract. If
     * the output token is the wrapped native token for the chain, then the recipient will receive the native token if
     * an EOA or wrapped native token if a contract.
     * @param inputToken The token pulled from the caller's account and locked into this contract to initiate the deposit.
     * Equivalent tokens on the relayer's repayment chain will be sent as a refund. If this is the wrapped native token,
     * msg.value must equal inputTokenAmount when passed.
     * @param outputToken The token the relayer will send to the recipient on the destination chain. Must be an ERC20.
     * @param inputAmount The amount of input tokens pulled from the caller's account and locked into this contract.
     * This amount will be sent to the relayer as a refund following an optimistic challenge window in the HubPool, plus a system fee.
     * @param outputAmount The amount of output tokens the relayer will send to the recipient on the destination.
     * @param destinationChainId The destination chain identifier. Must be enabled with the input token as a valid deposit route
     * from this spoke pool, or the transaction will revert.
     * @param exclusiveRelayer The relayer exclusively allowed to fill the deposit before the exclusivity deadline.
     * @param fillDeadlineOffset Added to the current time to set the fill deadline. After this timestamp, fills on the
     * destination chain will revert.
     * @param exclusivityPeriod Added to the current time to set the exclusive relayer deadline. After this timestamp,
     * anyone can fill the deposit until the fill deadline.
     * @param message The message to send to the recipient on the destination chain. If the recipient is a contract, it must
     * implement `handleV3AcrossMessage()` if the message is not empty, or the fill will revert.
     */
    function depositV3Now(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 fillDeadlineOffset,
        uint32 exclusivityPeriod,
        bytes calldata message
    ) external payable {
        depositV3(
            depositor,
            recipient,
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            uint32(getCurrentTime()),
            uint32(getCurrentTime()) + fillDeadlineOffset,
            exclusivityPeriod,
            message
        );
    }

    /**
     * @notice DEPRECATED. Use depositV3() instead.
     * @notice Submits deposit and sets exclusivityDeadline to current time plus some offset. This function is
     * designed to be called by users who want to set an exclusive relayer for some amount of time after their deposit
     * transaction is mined.
     * @notice If exclusivtyDeadlineOffset > 0, then exclusiveRelayer must be set to a valid address, which is a
     * requirement imposed by depositV3().
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
     * @param exclusivityPeriod Added to the current time to set the exclusive relayer deadline,
     * which is the deadline for the exclusiveRelayer to fill the deposit. After this destination chain timestamp,
     * anyone can fill the deposit.
     * @param message The message to send to the recipient on the destination chain if the recipient is a contract.
     * If the message is not empty, the recipient contract must implement handleV3AcrossMessage() or the fill will revert.
     */
    function depositExclusive(
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
        uint32 exclusivityPeriod,
        bytes calldata message
    ) public payable {
        depositV3(
            depositor.toBytes32(),
            recipient.toBytes32(),
            inputToken.toBytes32(),
            outputToken.toBytes32(),
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer.toBytes32(),
            quoteTimestamp,
            fillDeadline,
            exclusivityPeriod,
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
        bytes32 depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) public override nonReentrant {
        _verifyUpdateV3DepositMessage(
            depositor.toAddress(),
            depositId,
            chainId(),
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            depositorSignature,
            UPDATE_V3_DEPOSIT_DETAILS_HASH
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

    /**
     * @notice An overloaded version of `speedUpV3Deposit` using `address` types for backward compatibility.
     * This function allows the depositor to signal to the relayer to use updated output amount, recipient, and/or message
     * when filling a deposit. This can be useful when the deposit needs to be modified after the original transaction has
     * been mined.
     *
     * @dev The `depositor` and `depositId` must match the parameters in a `V3FundsDeposited` event that the depositor wants to speed up.
     * The relayer is not obligated but has the option to use this updated information when filling the deposit using
     * `fillV3RelayWithUpdatedDeposit()`. This version uses `address` types for compatibility with systems relying on
     * `address`-based implementations.
     *
     * @param depositor The depositor that must sign the `depositorSignature` and was the original depositor.
     * @param depositId The deposit ID to speed up.
     * @param updatedOutputAmount The new output amount to use for this deposit. It should be lower than the previous value,
     * otherwise the relayer has no incentive to use this updated value.
     * @param updatedRecipient The new recipient for this deposit. Can be modified if the original recipient is a contract that
     * expects to receive a message from the relay and needs to be changed.
     * @param updatedMessage The new message for this deposit. Can be modified if the recipient is a contract that expects
     * to receive a message from the relay and needs to be updated.
     * @param depositorSignature The signed EIP712 hashstruct containing the deposit ID. Should be signed by the depositor account.
     * If the depositor is a contract, it should implement EIP1271 to sign as a contract. See `_verifyUpdateV3DepositMessage()`
     * for more details on how the signature should be constructed.
     */
    function speedUpV3Deposit(
        address depositor,
        uint32 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) public {
        _verifyUpdateV3DepositMessage(
            depositor,
            depositId,
            chainId(),
            updatedOutputAmount,
            updatedRecipient.toBytes32(),
            updatedMessage,
            depositorSignature,
            UPDATE_V3_DEPOSIT_ADDRESS_OVERLOAD_DETAILS_HASH
        );

        // Assuming the above checks passed, a relayer can take the signature and the updated deposit information
        // from the following event to submit a fill with updated relay data.
        emit RequestedSpeedUpV3Deposit(
            updatedOutputAmount,
            depositId,
            depositor.toBytes32(),
            updatedRecipient.toBytes32(),
            updatedMessage,
            depositorSignature
        );
    }

    /**************************************
     *         RELAYER FUNCTIONS          *
     **************************************/

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
     * timestamp, anyone can fill this deposit. Note that if this value was set in depositV3 by adding an offset
     * to the deposit's block.timestamp, there is re-org risk for the caller of this method because the event's
     * block.timestamp can change. Read the comments in `depositV3` about the `exclusivityParameter` for more details.
     * - message The message to send to the recipient if the recipient is a contract that implements a
     * handleV3AcrossMessage() public function
     * @param repaymentChainId Chain of SpokePool where relayer wants to be refunded after the challenge window has
     * passed. Will receive inputAmount of the equivalent token to inputToken on the repayment chain.
     */
    function fillV3Relay(
        V3RelayData calldata relayData,
        uint256 repaymentChainId,
        bytes32 repaymentAddress
    ) public override nonReentrant unpausedFills {
        // Exclusivity deadline is inclusive and is the latest timestamp that the exclusive relayer has sole right
        // to fill the relay.
        if (
            _fillIsExclusive(relayData.exclusivityDeadline, uint32(getCurrentTime())) &&
            relayData.exclusiveRelayer.toAddress() != msg.sender
        ) {
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

        _fillRelayV3(relayExecution, repaymentAddress, false);
    }

    /**
     * @notice Identical to fillV3Relay except that the relayer wants to use a depositor's updated output amount,
     * recipient, and/or message. The relayer should only use this function if they can supply a message signed
     * by the depositor that contains the fill's matching deposit ID along with updated relay parameters.
     * If the signature can be verified, then this function will emit a FilledV3Event that will be used by
     * the system for refund verification purposes. In other words, this function is an alternative way to fill a
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
        bytes32 repaymentAddress,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) public override nonReentrant unpausedFills {
        // Exclusivity deadline is inclusive and is the latest timestamp that the exclusive relayer has sole right
        // to fill the relay.
        if (
            _fillIsExclusive(relayData.exclusivityDeadline, uint32(getCurrentTime())) &&
            relayData.exclusiveRelayer.toAddress() != msg.sender
        ) {
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
            relayData.depositor.toAddress(),
            relayData.depositId,
            relayData.originChainId,
            updatedOutputAmount,
            updatedRecipient,
            updatedMessage,
            depositorSignature,
            UPDATE_V3_DEPOSIT_DETAILS_HASH
        );

        _fillRelayV3(relayExecution, repaymentAddress, false);
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
        uint32 currentTime = uint32(getCurrentTime());
        // If a depositor has set an exclusivity deadline, then only the exclusive relayer should be able to
        // fast fill within this deadline. Moreover, the depositor should expect to get *fast* filled within
        // this deadline, not slow filled. As a simplifying assumption, we will not allow slow fills to be requested
        // during this exclusivity period.
        if (_fillIsExclusive(relayData.exclusivityDeadline, currentTime)) {
            revert NoSlowFillsInExclusivityWindow();
        }
        if (relayData.fillDeadline < currentTime) revert ExpiredFillDeadline();

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

    /**
     * @notice Fills a single leg of a particular order on the destination chain
     * @dev ERC-7683 fill function.
     * @param orderId Unique order identifier for this order
     * @param originData Data emitted on the origin to parameterize the fill
     * @param fillerData Data provided by the filler to inform the fill or express their preferences
     */
    function fill(
        bytes32 orderId,
        bytes calldata originData,
        bytes calldata fillerData
    ) external {
        if (keccak256(abi.encode(originData, chainId())) != orderId) {
            revert WrongERC7683OrderId();
        }

        // Ensure that the call is not malformed. If the call is malformed, abi.decode will fail.
        V3SpokePoolInterface.V3RelayData memory relayData = abi.decode(originData, (V3SpokePoolInterface.V3RelayData));
        AcrossDestinationFillerData memory destinationFillerData = abi.decode(
            fillerData,
            (AcrossDestinationFillerData)
        );

        // Must do a delegatecall because the function requires the inputs to be calldata.
        (bool success, bytes memory data) = address(this).delegatecall(
            abi.encodeCall(
                V3SpokePoolInterface.fillV3Relay,
                (relayData, destinationFillerData.repaymentChainId, msg.sender.toBytes32())
            )
        );
        if (!success) {
            revert LowLevelCallFailed(data);
        }
    }

    /**************************************
     *         DATA WORKER FUNCTIONS      *
     **************************************/

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

        _preExecuteLeafHook(relayData.outputToken.toAddress());

        // @TODO In the future consider allowing way for slow fill leaf to be created with updated
        // deposit params like outputAmount, message and recipient.
        V3RelayExecutionParams memory relayExecution = V3RelayExecutionParams({
            relay: relayData,
            relayHash: _getV3RelayHash(relayData),
            updatedOutputAmount: slowFillLeaf.updatedOutputAmount,
            updatedRecipient: relayData.recipient,
            updatedMessage: relayData.message,
            repaymentChainId: EMPTY_REPAYMENT_CHAIN_ID // Repayment not relevant for slow fills.
        });

        _verifyV3SlowFill(relayExecution, rootBundleId, proof);

        // - No relayer to refund for slow fill executions.
        _fillRelayV3(relayExecution, EMPTY_RELAYER, true);
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
        if (!MerkleLib.verifyRelayerRefund(rootBundle.relayerRefundRoot, relayerRefundLeaf, proof)) {
            revert InvalidMerkleProof();
        }

        _setClaimedLeaf(rootBundleId, relayerRefundLeaf.leafId);

        bool deferredRefunds = _distributeRelayerRefunds(
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
            deferredRefunds,
            msg.sender
        );
    }

    /**
     * @notice Enables a relayer to claim outstanding repayments. Should virtually never be used, unless for some reason
     * relayer repayment transfer fails for reasons such as token transfer reverts due to blacklisting. In this case,
     * the relayer can still call this method and claim the tokens to a new address.
     * @param l2TokenAddress Address of the L2 token to claim refunds for.
     * @param refundAddress Address to send the refund to.
     */
    function claimRelayerRefund(bytes32 l2TokenAddress, bytes32 refundAddress) public {
        uint256 refund = relayerRefund[l2TokenAddress.toAddress()][msg.sender];
        if (refund == 0) revert NoRelayerRefundToClaim();
        relayerRefund[l2TokenAddress.toAddress()][refundAddress.toAddress()] = 0;
        IERC20Upgradeable(l2TokenAddress.toAddress()).safeTransfer(refundAddress.toAddress(), refund);

        emit ClaimedRelayerRefund(l2TokenAddress, refundAddress, refund, msg.sender);
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

    function getRelayerRefund(address l2TokenAddress, address refundAddress) public view returns (uint256) {
        return relayerRefund[l2TokenAddress][refundAddress];
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    function _depositV3(
        bytes32 depositor,
        bytes32 recipient,
        address inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes calldata message
    ) internal {
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
        uint256 currentTime = getCurrentTime();
        if (currentTime - quoteTimestamp > depositQuoteTimeBuffer) revert InvalidQuoteTimestamp();

        // fillDeadline is relative to the destination chain.
        // Don’t allow fillDeadline to be more than several bundles into the future.
        // This limits the maximum required lookback for dataworker and relayer instances.
        // Also, don't allow fillDeadline to be in the past. This poses a potential UX issue if the destination
        // chain time keeping and this chain's time keeping are out of sync but is not really a practical hurdle
        // unless they are significantly out of sync or the depositor is setting very short fill deadlines. This latter
        // situation won't be a problem for honest users.
        if (fillDeadline < currentTime || fillDeadline > currentTime + fillDeadlineBuffer) revert InvalidFillDeadline();

        // There are three cases for setting the exclusivity deadline using the exclusivity parameter:
        // 1. If this parameter is 0, then there is no exclusivity period and emit 0 for the deadline. This
        //    means that fillers of this deposit do not have to worry about the block.timestamp of this event changing
        //    due to re-orgs when filling this deposit.
        // 2. If the exclusivity parameter is less than or equal to MAX_EXCLUSIVITY_PERIOD_SECONDS, then the exclusivity
        //    deadline is set to the block.timestamp of this event plus the exclusivity parameter. This means that the
        //    filler of this deposit assumes re-org risk when filling this deposit because the block.timestamp of this
        //    event affects the exclusivity deadline.
        // 3. Otherwise, interpret this parameter as a timestamp and emit it as the exclusivity deadline. This means
        //    that the filler of this deposit will not assume re-org risk related to the block.timestamp of this
        //    event changing.
        uint32 exclusivityDeadline = exclusivityParameter;
        if (exclusivityDeadline > 0) {
            if (exclusivityDeadline <= MAX_EXCLUSIVITY_PERIOD_SECONDS) {
                exclusivityDeadline += uint32(currentTime);
            }

            // As a safety measure, prevent caller from inadvertently locking funds during exclusivity period
            //  by forcing them to specify an exclusive relayer.
            if (exclusiveRelayer == bytes32(0)) revert InvalidExclusiveRelayer();
        }

        // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // transaction then the user is sending the native token. In this case, the native token should be
        // wrapped.
        if (inputToken == address(wrappedNativeToken) && msg.value > 0) {
            if (msg.value != inputAmount) revert MsgValueDoesNotMatchInputAmount();
            wrappedNativeToken.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the caller as per normal.
            // Note: this includes the case where the L2 caller has WETH (already wrapped ETH) and wants to bridge them.
            // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else {
            // msg.value should be 0 if input token isn't the wrapped native token.
            if (msg.value != 0) revert MsgValueDoesNotMatchInputAmount();
            IERC20Upgradeable(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        emit V3FundsDeposited(
            inputToken.toBytes32(),
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            depositId,
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            depositor,
            recipient,
            exclusiveRelayer,
            message
        );
    }

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
        if (!enabledDepositRoutes[originToken][destinationChainId]) revert DisabledRoute();

        // We limit the relay fees to prevent the user spending all their funds on fees.
        if (SignedMath.abs(relayerFeePct) >= 0.5e18) revert InvalidRelayerFeePct();
        if (amount > MAX_TRANSFER_SIZE) revert MaxTransferSizeExceeded();

        // Require that quoteTimestamp has a maximum age so that depositors pay an LP fee based on recent HubPool usage.
        // It is assumed that cross-chain timestamps are normally loosely in-sync, but clock drift can occur. If the
        // SpokePool time stalls or lags significantly, it is still possible to make deposits by setting quoteTimestamp
        // within the configured buffer. The owner should pause deposits if this is undesirable. This will underflow if
        // quoteTimestamp is more than depositQuoteTimeBuffer; this is safe but will throw an unintuitive error.

        // slither-disable-next-line timestamp
        if (getCurrentTime() - quoteTimestamp > depositQuoteTimeBuffer) revert InvalidQuoteTimestamp();

        // Increment count of deposits so that deposit ID for this spoke pool is unique.
        uint32 newDepositId = numberOfDeposits++;

        // If the address of the origin token is a wrappedNativeToken contract and there is a msg.value with the
        // transaction then the user is sending ETH. In this case, the ETH should be deposited to wrappedNativeToken.
        if (originToken == address(wrappedNativeToken) && msg.value > 0) {
            if (msg.value != amount) revert MsgValueDoesNotMatchInputAmount();
            wrappedNativeToken.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the user's wallet as per normal.
            // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them.
            // In this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else {
            IERC20Upgradeable(originToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        emit V3FundsDeposited(
            originToken.toBytes32(), // inputToken
            bytes32(0), // outputToken. Setting this to 0x0 means that the outputToken should be assumed to be the
            // canonical token for the destination chain matching the inputToken. Therefore, this deposit
            // can always be slow filled.
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
            INFINITE_FILL_DEADLINE, // fillDeadline. Default to infinite expiry because
            // expired deposits refunds could be a breaking change for existing users of this function.
            0, // exclusivityDeadline. Setting this to 0 along with the exclusiveRelayer to 0x0 means that there
            // is no exclusive deadline
            depositor.toBytes32(),
            recipient.toBytes32(),
            bytes32(0), // exclusiveRelayer. Setting this to 0x0 will signal to off-chain validator that there
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
    ) internal returns (bool deferredRefunds) {
        uint256 numRefunds = refundAmounts.length;
        if (refundAddresses.length != numRefunds) revert InvalidMerkleLeaf();

        if (numRefunds > 0) {
            uint256 spokeStartBalance = IERC20Upgradeable(l2TokenAddress).balanceOf(address(this));
            uint256 totalRefundedAmount = 0; // Track the total amount refunded.

            // Send each relayer refund address the associated refundAmount for the L2 token address.
            // Note: Even if the L2 token is not enabled on this spoke pool, we should still refund relayers.
            for (uint256 i = 0; i < numRefunds; ++i) {
                if (refundAmounts[i] > 0) {
                    totalRefundedAmount += refundAmounts[i];

                    // Only if the total refunded amount exceeds the spoke starting balance, should we revert. This
                    // ensures that bundles are atomic, if we have sufficient balance to refund all relayers and
                    // prevents can only re-pay some of the relayers.
                    if (totalRefundedAmount > spokeStartBalance) revert InsufficientSpokePoolBalanceToExecuteLeaf();

                    bool success = _noRevertTransfer(l2TokenAddress, refundAddresses[i], refundAmounts[i]);

                    // If the transfer failed then track a deferred transfer for the relayer. Given this function would
                    // have revered if there was insufficient balance, this will only happen if the transfer call
                    // reverts. This will only occur if the underlying transfer method on the l2Token reverts due to
                    // recipient blacklisting or other related modifications to the l2Token.transfer method.
                    if (!success) {
                        relayerRefund[l2TokenAddress][refundAddresses[i]] += refundAmounts[i];
                        deferredRefunds = true;
                    }
                }
            }
        }
        // If leaf's amountToReturn is positive, then send L2 --> L1 message to bridge tokens back via
        // chain-specific bridging method.
        if (amountToReturn > 0) {
            _bridgeTokensToHubPool(amountToReturn, l2TokenAddress);

            emit TokensBridged(amountToReturn, _chainId, leafId, l2TokenAddress.toBytes32(), msg.sender);
        }
    }

    // Re-implementation of OZ _callOptionalReturnBool to use private logic. Function executes a transfer and returns a
    // bool indicating if the external call was successful, rather than reverting. Original method:
    // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/28aed34dc5e025e61ea0390c18cac875bfde1a78/contracts/token/ERC20/utils/SafeERC20.sol#L188
    function _noRevertTransfer(
        address token,
        address to,
        uint256 amount
    ) internal returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        bytes memory data = abi.encodeCall(IERC20Upgradeable.transfer, (to, amount));
        assembly {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }

    function _setCrossDomainAdmin(address newCrossDomainAdmin) internal {
        if (newCrossDomainAdmin == address(0)) revert InvalidCrossDomainAdmin();
        crossDomainAdmin = newCrossDomainAdmin;
        emit SetXDomainAdmin(newCrossDomainAdmin);
    }

    function _setWithdrawalRecipient(address newWithdrawalRecipient) internal {
        if (newWithdrawalRecipient == address(0)) revert InvalidWithdrawalRecipient();
        withdrawalRecipient = newWithdrawalRecipient;
        emit SetWithdrawalRecipient(newWithdrawalRecipient);
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

    function _verifyUpdateV3DepositMessage(
        address depositor,
        uint32 depositId,
        uint256 originChainId,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes memory updatedMessage,
        bytes memory depositorSignature,
        bytes32 hashType
    ) internal view {
        // A depositor can request to modify an un-relayed deposit by signing a hash containing the updated
        // details and information uniquely identifying the deposit to relay. This information ensures
        // that this signature cannot be re-used for other deposits.
        bytes32 expectedTypedDataV4Hash = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    hashType,
                    depositId,
                    originChainId,
                    updatedOutputAmount,
                    updatedRecipient,
                    keccak256(updatedMessage)
                )
            ),
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
        // - We don't need to worry about re-entrancy from a contract deployed at the depositor address since the method
        //   `SignatureChecker.isValidSignatureNow` is a view method. Re-entrancy can happen, but it cannot affect state.
        // - EIP-1271 signatures are supported. This means that a signature valid now, may not be valid later and vice-versa.
        // - For an EIP-1271 signature to work, the depositor contract address must map to a deployed contract on the destination
        //   chain that can validate the signature.
        // - Regular signatures from an EOA are also supported.
        bool isValid = SignatureChecker.isValidSignatureNow(depositor, ethSignedMessageHash, depositorSignature);
        if (!isValid) revert InvalidDepositorSignature();
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

        if (!MerkleLib.verifyV3SlowRelayFulfillment(rootBundles[rootBundleId].slowRelayRoot, slowFill, proof)) {
            revert InvalidMerkleProof();
        }
    }

    function _computeAmountPostFees(uint256 amount, int256 feesPct) private pure returns (uint256) {
        return (amount * uint256(int256(1e18) - feesPct)) / 1e18;
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

    // @param relayer: relayer who is actually credited as filling this deposit. Can be different from
    // exclusiveRelayer if passed exclusivityDeadline or if slow fill.
    function _fillRelayV3(
        V3RelayExecutionParams memory relayExecution,
        bytes32 relayer,
        bool isSlowFill
    ) internal {
        V3RelayData memory relayData = relayExecution.relay;

        if (relayData.fillDeadline < getCurrentTime()) revert ExpiredFillDeadline();

        bytes32 relayHash = relayExecution.relayHash;

        // If a slow fill for this fill was requested then the relayFills value for this hash will be
        // FillStatus.RequestedSlowFill. Therefore, if this is the status, then this fast fill
        // will be replacing the slow fill. If this is a slow fill execution, then the following variable
        // is trivially true. We'll emit this value in the FilledV3Relay
        // event to assist the Dataworker in knowing when to return funds back to the HubPool that can no longer
        // be used for a slow fill execution.
        FillType fillType = isSlowFill
            ? FillType.SlowFill // The following is true if this is a fast fill that was sent after a slow fill request.
            : (
                fillStatuses[relayExecution.relayHash] == uint256(FillStatus.RequestedSlowFill)
                    ? FillType.ReplacedSlowFill
                    : FillType.FastFill
            );

        // @dev This function doesn't support partial fills. Therefore, we associate the relay hash with
        // an enum tracking its fill status. All filled relays, whether slow or fast fills, are set to the Filled
        // status. However, we also use this slot to track whether this fill had a slow fill requested. Therefore
        // we can include a bool in the FilledV3Relay event making it easy for the dataworker to compute if this
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
        address recipientToSend = relayExecution.updatedRecipient.toAddress();

        if (msg.sender == recipientToSend && !isSlowFill) return;

        // If relay token is wrappedNativeToken then unwrap and send native token.
        address outputToken = relayData.outputToken.toAddress();
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
        if (updatedMessage.length > 0 && recipientToSend.isContract()) {
            AcrossMessageHandler(recipientToSend).handleV3AcrossMessage(
                outputToken,
                amountToSend,
                msg.sender,
                updatedMessage
            );
        }
    }

    // Determine whether the exclusivityDeadline implies active exclusivity.
    function _fillIsExclusive(uint32 exclusivityDeadline, uint32 currentTime) internal pure returns (bool) {
        return exclusivityDeadline >= currentTime;
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
    uint256[998] private __gap;
}
