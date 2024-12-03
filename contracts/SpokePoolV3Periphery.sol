//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";
import { Lockable } from "./Lockable.sol";
import { V3SpokePoolInterface } from "./interfaces/V3SpokePoolInterface.sol";
import { IERC20Auth } from "./external/interfaces/IERC20Auth.sol";
import { WETH9Interface } from "./external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "./external/interfaces/IPermit2.sol";

/**
 * @title SpokePoolProxy
 * @notice User should only call the SpokePoolV3Periphery contract functions through this
 * contract. This is purposefully a simple passthrough contract so that the user only approves (or permits or
 * authorizes) this contract to pull its assets while the SpokePoolV3Periphery contract can be used to call
 * any calldata on any exchange that the user wants to. By separating the contract that pulls user funds from the
 * contract that executes arbitrary calldata, the SpokePoolPeriphery does not need to validate the calldata
 * that gets executed. If the user's request to pull funds into this contract gets front-run, then there won't be
 * avenues for a blackhat to exploit the user because they'd still need to make a call on the SpokePoolPeriphery
 * contract through this contract but they wouldn't have access to the user's signature.
 * @dev If this proxy didn't exist and users instead approved and interacted directly with the SpokePoolV3Periphery
 * then users would run the unneccessary risk that another user could instruct the Periphery contract to steal
 * any approved tokens that the user had left outstanding.
 */
contract SpokePoolPeripheryProxy is Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    bytes private constant ACROSS_DEPOSIT_DATA_TYPE =
        abi.encodePacked(
            "DepositData(",
            "address outputToken",
            "uint256 outputAmount",
            "address depositor",
            "address recipient",
            "uint256 destinationChainId",
            "address exclusiveRelayer",
            "uint32 quoteTimestamp",
            "uint32 fillDeadline",
            "uint32 exclusivityParameter",
            "bytes message)"
        );
    bytes32 private constant ACROSS_DEPOSIT_DATA_TYPEHASH = keccak256(ACROSS_DEPOSIT_DATA_TYPE);
    string private constant ACROSS_DEPOSIT_TYPE_STRING =
        string(
            abi.encodePacked(
                "DepositData witness)",
                ACROSS_DEPOSIT_DATA_TYPE,
                "TokenPermissions(address token, uint256 amount)"
            )
        );

    // Flag set for one time initialization.
    bool private initialized;

    // Canonical Permit2 contract address.
    IPermit2 public permit2;

    // The SpokePoolPeriphery should be deterministically deployed at the same address across all networks,
    // so this contract should also be able to be deterministically deployed at the same address across all networks
    // since the periphery address is the only constructor argument.
    SpokePoolV3Periphery public SPOKE_POOL_PERIPHERY;

    error LeftoverInputTokens();
    error InvalidPeriphery();
    error InvalidPermit2();
    error ContractInitialized();
    error InvalidSignature();

    /**
     * @notice Construct a new Proxy contract.
     * @dev Is empty and all of the state variables are initialized in the initialize function
     * to allow for deployment at a deterministic address via create2, which requires that the bytecode
     * across different networks is the same. Constructor parameters affect the bytecode so we can only
     * add parameters here that are consistent across networks.
     */
    constructor() {}

    /**
     * @notice Initialize the SpokePoolPeripheryProxy contract.
     * @param _spokePoolPeriphery Address of the SpokePoolPeriphery contract that this proxy will call.
     */
    function initialize(SpokePoolV3Periphery _spokePoolPeriphery, IPermit2 _permit2) external nonReentrant {
        if (initialized) revert ContractInitialized();
        initialized = true;
        if (!address(_spokePoolPeriphery).isContract()) revert InvalidPeriphery();
        SPOKE_POOL_PERIPHERY = _spokePoolPeriphery;
        if (!address(_permit2).isContract()) revert InvalidPermit2();
        permit2 = _permit2;
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param swapData Specifies the params we need to perform a swap on a generic exchange.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 acrossInputToken,
        SpokePoolV3Periphery.SwapData calldata swapData,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) external nonReentrant {
        swapData.swapToken.safeTransferFrom(msg.sender, address(this), swapData.swapTokenAmount);
        _callSwapAndBridge(acrossInputToken, swapData, depositData);
    }

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If the swapToken in swapData does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param swapData Specifies the params we need to perform a swap on a generic exchange.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v)
     */
    function swapAndBridgeWithPermit(
        IERC20 acrossInputToken,
        SpokePoolV3Periphery.SwapData calldata swapData,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(permitSignature);
        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try
            IERC20Permit(address(swapData.swapToken)).permit(
                msg.sender,
                address(this),
                swapData.swapTokenAmount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        _callSwapAndBridge(acrossInputToken, swapData, depositData);
    }

    /**
     * @notice Uses permit2 to transfer tokens from a user before swapping a token on this chain via specified router and submitting an Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param depositor The owner of the permit2 signature and depositor for the Across spoke pool.
     * @param swapData Specifies the params we need to perform a swap on a generic exchange.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param permit The permit data signed over by the owner.
     * @param transferDetails The spender's requested transfer details for the permitted token.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function swapAndBridgeWithPermit2(
        IERC20 acrossInputToken,
        address depositor,
        SpokePoolV3Periphery.SwapData calldata swapData,
        SpokePoolV3Periphery.DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature
    ) external nonReentrant {
        bytes32 witness = keccak256(
            abi.encode(
                ACROSS_DEPOSIT_DATA_TYPEHASH,
                depositData.outputToken,
                depositData.outputAmount,
                depositData.depositor,
                depositData.recipient,
                depositData.destinationChainId,
                depositData.exclusiveRelayer,
                depositData.quoteTimestamp,
                depositData.fillDeadline,
                depositData.exclusivityParameter,
                depositData.message
            )
        );
        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            depositor,
            witness,
            ACROSS_DEPOSIT_TYPE_STRING,
            signature
        );
        _callSwapAndBridge(acrossInputToken, swapData, depositData);
    }

    /**
     * @notice Swaps an EIP-3009 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param swapData Specifies the params we need to perform a swap on a generic exchange.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function swapAndBridgeWithAuthorization(
        IERC20 acrossInputToken,
        SpokePoolV3Periphery.SwapData calldata swapData,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(receiveWithAuthSignature);
        // While any contract can vacuously implement `transferWithAuthorization` (or just have a fallback),
        // if tokens were not sent to this contract, by this call to swapData.swapToken, this function will revert
        // when attempting to swap tokens it does not own.
        IERC20Auth(address(swapData.swapToken)).receiveWithAuthorization(
            msg.sender,
            address(this),
            swapData.swapTokenAmount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );
        _callSwapAndBridge(acrossInputToken, swapData, depositData);
    }

    /**
     * @notice Deposits an ERC20 token into the Spoke Pool contract.
     * @dev User should probably just call SpokePool.depositV3 directly to save marginal gas costs,
     * but this is added here for convenience in case caller only wants to interface Across through a single
     * address.
     * @param acrossInputToken ERC20 token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     */
    function depositERC20(
        IERC20 acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) external nonReentrant {
        IERC20(acrossInputToken).safeTransferFrom(msg.sender, address(this), acrossInputAmount);
        _callDeposit(IERC20(address(acrossInputToken)), acrossInputAmount, depositData);
    }

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param acrossInputToken EIP-2612 compliant token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     * @param deadline Deadline before which the permit signature is valid.
     * @param permitSignature Permit signature encoded as (bytes32 r, bytes32 s, uint8 v)
     */
    function depositWithPermit(
        IERC20Permit acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 deadline,
        bytes calldata permitSignature
    ) external nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(permitSignature);
        IERC20 _acrossInputToken = IERC20(address(acrossInputToken)); // Cast IERC20Permit to an IERC20 type.
        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try acrossInputToken.permit(msg.sender, address(this), acrossInputAmount, deadline, v, r, s) {} catch {}

        _callDeposit(_acrossInputToken, acrossInputAmount, depositData);
    }

    /**
     * @notice Uses permit2 to transfer and submit an Across deposit to the Spoke Pool contract.
     * @dev This function assumes the caller has properly set an allowance for the permit2 contract on this network.
     * @dev This function assumes that the amount of token to be swapped is equal to the amount of the token to be received from permit2.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param permit The permit data signed over by the owner.
     * @param transferDetails The spender's requested transfer details for the permitted token.
     * @param signature The permit2 signature to verify against the deposit data.
     */
    function depositWithPermit2(
        address depositor,
        SpokePoolV3Periphery.DepositData calldata depositData,
        IPermit2.PermitTransferFrom calldata permit,
        IPermit2.SignatureTransferDetails calldata transferDetails,
        bytes calldata signature
    ) external nonReentrant {
        bytes32 witness = keccak256(
            abi.encode(
                ACROSS_DEPOSIT_DATA_TYPEHASH,
                depositData.outputToken,
                depositData.outputAmount,
                depositData.depositor,
                depositData.recipient,
                depositData.destinationChainId,
                depositData.exclusiveRelayer,
                depositData.quoteTimestamp,
                depositData.fillDeadline,
                depositData.exclusivityParameter,
                depositData.message
            )
        );
        permit2.permitWitnessTransferFrom(
            permit,
            transferDetails,
            depositor,
            witness,
            ACROSS_DEPOSIT_TYPE_STRING,
            signature
        );
        _callDeposit(IERC20(permit.permitted.token), permit.permitted.amount, depositData);
    }

    /**
     * @notice Deposits an EIP-3009 compliant Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param acrossInputToken EIP-3009 compliant token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param receiveWithAuthSignature EIP3009 signature encoded as (bytes32 r, bytes32 s, uint8 v).
     */
    function depositWithAuthorization(
        IERC20Auth acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata receiveWithAuthSignature
    ) external nonReentrant {
        (bytes32 r, bytes32 s, uint8 v) = _deserializeSignature(receiveWithAuthSignature);
        acrossInputToken.receiveWithAuthorization(
            msg.sender,
            address(this),
            acrossInputAmount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );
        _callDeposit(IERC20(address(acrossInputToken)), acrossInputAmount, depositData);
    }

    function _callSwapAndBridge(
        IERC20 acrossInputToken,
        SpokePoolV3Periphery.SwapData calldata swapData,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) internal {
        swapData.swapToken.forceApprove(address(SPOKE_POOL_PERIPHERY), swapData.swapTokenAmount);
        SPOKE_POOL_PERIPHERY.swapAndBridge(acrossInputToken, swapData, depositData);
    }

    function _callDeposit(
        IERC20 acrossInputToken,
        uint256 acrossInputAmount,
        SpokePoolV3Periphery.DepositData calldata depositData
    ) internal {
        acrossInputToken.forceApprove(address(SPOKE_POOL_PERIPHERY), acrossInputAmount);
        SPOKE_POOL_PERIPHERY.depositERC20(acrossInputToken, acrossInputAmount, depositData);
    }

    function _deserializeSignature(bytes calldata _signature)
        private
        pure
        returns (
            bytes32 r,
            bytes32 s,
            uint8 v
        )
    {
        if (_signature.length != 65) revert InvalidSignature();
        v = uint8(_signature[64]);
        r = bytes32(_signature[0:32]);
        s = bytes32(_signature[32:64]);
    }
}

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
contract SpokePoolV3Periphery is Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // Enum describing the method of transferring tokens to an exchange.
    enum TransferType {
        // Approve the exchange so that it may transfer tokens from this contract.
        Approval,
        // Transfer tokens to the exchange before calling it in this contract.
        Transfer,
        // Approve the exchange by use of an EIP1271 callback.
        EIP1271Signature
    }

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    V3SpokePoolInterface public spokePool;

    // Wrapped native token contract address.
    WETH9Interface public wrappedNativeToken;

    // Canonical Permit2 contract address.
    IPermit2 public permit2;

    // Address of the proxy contract that users should interact with to call this contract.
    // Force users to call through this contract to make sure they don't leave any approvals/permits
    // outstanding on this contract that could be abused because this contract executes arbitrary
    // calldata.
    address public proxy;

    // Nonce for this contract to use for EIP1217 "signatures".
    uint48 private nonce;

    // Boolean indicating whether the contract is initialized.
    bool private initialized;

    // Slot for keeping a swap identifier. Used to confirm whether a signature originated from this contract or not.
    // When solidity 0.8.24 becomes more widely available, this should be replaced with a TSTORE caching method.
    bytes32 private cachedSwapHash;

    // EIP 1217 magic bytes indicating a valid signature.
    bytes4 private constant EIP1217_VALID_SIGNATURE = 0x1626ba7e;

    // EIP 1217 bytes indicating an invalid signature.
    bytes4 private constant EIP1217_INVALID_SIGNATURE = 0xffffffff;

    // Params we'll need caller to pass in to specify an Across Deposit. The input token will be swapped into first
    // before submitting a bridge deposit, which is why we don't include the input token amount as it is not known
    // until after the swap.
    struct DepositData {
        // Token received on destination chain.
        address outputToken;
        // Amount of output token to be received by recipient.
        uint256 outputAmount;
        // The account credited with deposit who can submit speedups to the Across deposit.
        address depositor;
        // The account that will receive the output token on the destination chain. If the output token is
        // wrapped native token, then if this is an EOA then they will receive native token on the destination
        // chain and if this is a contract then they will receive an ERC20.
        address recipient;
        // The destination chain identifier.
        uint256 destinationChainId;
        // The account that can exclusively fill the deposit before the exclusivity parameter.
        address exclusiveRelayer;
        // Timestamp of the deposit used by system to charge fees. Must be within short window of time into the past
        // relative to this chain's current time or deposit will revert.
        uint32 quoteTimestamp;
        // The timestamp on the destination chain after which this deposit can no longer be filled.
        uint32 fillDeadline;
        // The timestamp or offset on the destination chain after which anyone can fill the deposit. A detailed description on
        // how the parameter is interpreted by the V3 spoke pool can be found at https://github.com/across-protocol/contracts/blob/fa67f5e97eabade68c67127f2261c2d44d9b007e/contracts/SpokePool.sol#L476
        uint32 exclusivityParameter;
        // Data that is forwarded to the recipient if the recipient is a contract.
        bytes message;
    }

    // Minimum amount of parameters needed to perform a swap on an exchange specified. We include information beyond just the router calldata
    // and exchange address so that we may ensure that the swap was performed properly.
    struct SwapData {
        // Token to swap.
        IERC20 swapToken;
        // Address of the exchange to use in the swap.
        address exchange;
        // Method of transferring tokens to the exchange.
        SpokePoolV3Periphery.TransferType transferType;
        // Amount of the token to swap on the exchange.
        uint256 swapTokenAmount;
        // Minimum output amount of the exchange, and, by extension, the minimum required amount to deposit into an Across spoke pool.
        uint256 minExpectedInputTokenAmount;
        // The calldata to use when calling the exchange.
        bytes routerCalldata;
    }

    event SwapBeforeBridge(
        address exchange,
        bytes exchangeCalldata,
        address indexed swapToken,
        address indexed acrossInputToken,
        uint256 swapTokenAmount,
        uint256 acrossInputAmount,
        address indexed acrossOutputToken,
        uint256 acrossOutputAmount
    );

    /****************************************
     *                ERRORS                *
     ****************************************/
    error MinimumExpectedInputAmount();
    error LeftoverSrcTokens();
    error ContractInitialized();
    error InvalidMsgValue();
    error InvalidSpokePool();
    error InvalidProxy();
    error InvalidSwapToken();
    error NotProxy();

    /**
     * @notice Construct a new SwapAndBridgeBase contract.
     * @dev Is empty and all of the state variables are initialized in the initialize function
     * to allow for deployment at a deterministic address via create2, which requires that the bytecode
     * across different networks is the same. Constructor parameters affect the bytecode so we can only
     * add parameters here that are consistent across networks.
     */
    constructor() {}

    modifier onlyProxy() {
        if (msg.sender != proxy) revert NotProxy();
        _;
    }

    /**
     * @notice Initializes the SwapAndBridgeBase contract.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     * @param _wrappedNativeToken Address of the wrapped native token for the network this contract is deployed to.
     * @param _proxy Address of the proxy contract that users should interact with to call this contract.
     * @dev These values are initialized in a function and not in the constructor so that the creation code of this contract
     * is the same across networks with different addresses for the wrapped native token and this network's
     * corresponding spoke pool contract. This is to allow this contract to be deterministically deployed with CREATE2.
     */
    function initialize(
        V3SpokePoolInterface _spokePool,
        WETH9Interface _wrappedNativeToken,
        address _proxy
    ) external nonReentrant {
        if (initialized) revert ContractInitialized();
        initialized = true;

        if (!address(_spokePool).isContract()) revert InvalidSpokePool();
        spokePool = _spokePool;
        wrappedNativeToken = _wrappedNativeToken;
        if (!_proxy.isContract()) revert InvalidProxy();
        proxy = _proxy;
    }

    /**
     * @notice Passthrough function to `depositV3()` on the SpokePool contract.
     * @dev Protects the caller from losing their ETH (or other native token) by reverting if the SpokePool address
     * they intended to call does not exist on this chain. Because this contract can be deployed at the same address
     * everywhere callers should be protected even if the transaction is submitted to an unintended network.
     * This contract should only be used for native token deposits, as this problem only exists for native tokens.
     * @param recipient Address to receive funds at on destination chain.
     * @param inputToken Token to lock into this contract to initiate deposit.
     * @param inputAmount Amount of tokens to deposit.
     * @param outputAmount Amount of tokens to receive on destination chain.
     * @param destinationChainId Denotes network where user will receive funds from SpokePool by a relayer.
     * @param quoteTimestamp Timestamp used by relayers to compute this deposit's realizedLPFeePct which is paid
     * to LP pool on HubPool.
     * @param message Arbitrary data that can be used to pass additional information to the recipient along with the tokens.
     * Note: this is intended to be used to pass along instructions for how a contract should use or allocate the tokens.
     * @param exclusiveRelayer Address of the relayer who has exclusive rights to fill this deposit. Can be set to
     * 0x0 if no period is desired. If so, then must set exclusivityParameter to 0.
     * @param exclusivityParameter Timestamp or offset, after which any relayer can fill this deposit. Must set
     * to 0 if exclusiveRelayer is set to 0x0, and vice versa.
     * @param fillDeadline Timestamp after which this deposit can no longer be filled.
     */
    function deposit(
        address recipient,
        address inputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityParameter,
        bytes memory message
    ) external payable nonReentrant {
        if (msg.value != inputAmount) revert InvalidMsgValue();
        if (!address(spokePool).isContract()) revert InvalidSpokePool();
        // Set msg.sender as the depositor so that msg.sender can speed up the deposit.
        spokePool.depositV3{ value: msg.value }(
            msg.sender,
            recipient,
            inputToken,
            // @dev Setting outputToken to 0x0 to instruct fillers to use the equivalent token
            // as the originToken on the destination chain.
            address(0),
            inputAmount,
            outputAmount,
            destinationChainId,
            exclusiveRelayer,
            quoteTimestamp,
            fillDeadline,
            exclusivityParameter,
            message
        );
    }

    /**
     * @notice Swaps tokens on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param swapData Specifies the data needed to perform a swap on a generic exchange.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 acrossInputToken,
        SwapData calldata swapData,
        DepositData calldata depositData
    ) external payable nonReentrant {
        // If a user performs a swapAndBridge with the swap token as the native token, wrap the value and treat the rest of transaction
        // as though the user deposited a wrapped native token.
        if (msg.value != 0) {
            if (msg.value != swapData.swapTokenAmount) revert InvalidMsgValue();
            if (address(swapData.swapToken) != address(wrappedNativeToken)) revert InvalidSwapToken();
            wrappedNativeToken.deposit{ value: msg.value }();
        } else {
            // If swap requires an approval to this contract, then force user to go through proxy
            // to prevent their approval from being abused.
            _calledByProxy();
            swapData.swapToken.safeTransferFrom(msg.sender, address(this), swapData.swapTokenAmount);
        }
        _swapAndBridge(swapData, depositData, acrossInputToken);
    }

    /**
     * @notice Calls depositV3 on spokepool.
     * @param acrossInputToken inputToken to deposit.
     * @param acrossInputAmount inputAmount to deposit.
     * @param depositData DepositData required to specify Across deposit.
     */
    function depositERC20(
        IERC20 acrossInputToken,
        uint256 acrossInputAmount,
        DepositData calldata depositData
    ) external nonReentrant onlyProxy {
        acrossInputToken.safeTransferFrom(msg.sender, address(this), acrossInputAmount);
        _depositV3(acrossInputToken, acrossInputAmount, depositData);
    }

    /**
     * @notice Verifies that the signer is the owner of the signing contract.
     * @param _signature The signature to verify.
     * @dev The _hash field is intentionally ignored since this contract only expects to receive data from permit2,
     * which should return an EIP712 hash of PermitSingle.
     */
    function isValidSignature(bytes32, bytes calldata _signature) external view returns (bytes4 magicBytes) {
        if (
            msg.sender != address(permit2) &&
            bytes32(_signature) == cachedSwapHash &&
            uint256(cachedSwapHash) != 0 &&
            _signature.length == 32
        ) {
            return EIP1217_VALID_SIGNATURE;
        }
        return EIP1217_INVALID_SIGNATURE;
    }

    /**
     * @notice Approves the spoke pool and calls `depositV3` function with the specified input parameters.
     * @param _acrossInputToken Token to deposit into the spoke pool.
     * @param _acrossInputAmount Amount of the input token to deposit into the spoke pool.
     * @param depositData Specifies the Across deposit params to use.
     */
    function _depositV3(
        IERC20 _acrossInputToken,
        uint256 _acrossInputAmount,
        DepositData calldata depositData
    ) private {
        _acrossInputToken.forceApprove(address(spokePool), _acrossInputAmount);
        spokePool.depositV3(
            depositData.depositor,
            depositData.recipient,
            address(_acrossInputToken), // input token
            depositData.outputToken, // output token
            _acrossInputAmount, // input amount.
            depositData.outputAmount, // output amount
            depositData.destinationChainId,
            depositData.exclusiveRelayer,
            depositData.quoteTimestamp,
            depositData.fillDeadline,
            depositData.exclusivityParameter,
            depositData.message
        );
    }

    // This contract supports two variants of swap and bridge, one that allows one token and another that allows the caller to pass them in.
    function _swapAndBridge(
        SwapData calldata swapData,
        DepositData calldata depositData,
        IERC20 _acrossInputToken
    ) private {
        // Load variables we use multiple times onto the stack.
        IERC20 _swapToken = swapData.swapToken;
        TransferType _transferType = swapData.transferType;
        address _exchange = swapData.exchange;
        uint256 _swapTokenAmount = swapData.swapTokenAmount;
        // Swap and run safety checks.
        uint256 srcBalanceBefore = _swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = _acrossInputToken.balanceOf(address(this));

        if (_transferType == TransferType.Approval) _swapToken.forceApprove(_exchange, _swapTokenAmount);
        else if (_transferType == TransferType.Transfer) _swapToken.transfer(_exchange, _swapTokenAmount);
        else {
            IPermit2.PermitSingle memory permitSingle = IPermit2.PermitSingle({
                details: IPermit2.PermitDetails({
                    token: address(_swapToken),
                    amount: uint160(_swapTokenAmount),
                    expiration: uint48(block.timestamp),
                    nonce: nonce++
                }),
                spender: _exchange,
                sigDeadline: block.timestamp
            });
            cachedSwapHash = keccak256(abi.encode(permitSingle, depositData.depositor));

            permit2.permit(
                address(this), // owner
                permitSingle, // permitSingle
                // Pass in a hash of the swap and deposit details to the permit2 contract so that this contract can check if it matches the cached data.
                abi.encodePacked(cachedSwapHash)
            );
        }
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = _exchange.call(swapData.routerCalldata);
        require(success, string(result));

        cachedSwapHash = bytes32(uint256(0));
        _checkSwapOutputAndDeposit(
            _exchange,
            swapData.routerCalldata,
            _swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            swapData.minExpectedInputTokenAmount,
            depositData,
            _swapToken,
            _acrossInputToken
        );
    }

    /**
     * @notice Check that the swap returned enough tokens to submit an Across deposit with and then submit the deposit.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of acrossInputToken.
     * @param swapTokenBalanceBefore Balance of swapToken before swap.
     * @param inputTokenBalanceBefore Amount of Across input token we held before swap
     * @param minExpectedInputTokenAmount Minimum amount of received acrossInputToken that we'll bridge
     **/
    function _checkSwapOutputAndDeposit(
        address exchange,
        bytes memory routerCalldata,
        uint256 swapTokenAmount,
        uint256 swapTokenBalanceBefore,
        uint256 inputTokenBalanceBefore,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData,
        IERC20 _swapToken,
        IERC20 _acrossInputToken
    ) private {
        // Sanity check that we received as many tokens as we require:
        uint256 returnAmount = _acrossInputToken.balanceOf(address(this)) - inputTokenBalanceBefore;
        // Sanity check that received amount from swap is enough to submit Across deposit with.
        if (returnAmount < minExpectedInputTokenAmount) revert MinimumExpectedInputAmount();
        // Sanity check that we don't have any leftover swap tokens that would be locked in this contract (i.e. check
        // that we weren't partial filled).
        if (swapTokenBalanceBefore - _swapToken.balanceOf(address(this)) != swapTokenAmount) revert LeftoverSrcTokens();

        emit SwapBeforeBridge(
            exchange,
            routerCalldata,
            address(_swapToken),
            address(_acrossInputToken),
            swapTokenAmount,
            returnAmount,
            depositData.outputToken,
            depositData.outputAmount
        );
        // Deposit the swapped tokens into Across and bridge them using remainder of input params.
        _depositV3(_acrossInputToken, returnAmount, depositData);
    }

    function _calledByProxy() internal view {
        if (msg.sender != proxy) revert NotProxy();
    }
}
