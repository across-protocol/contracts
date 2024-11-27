//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { MultiCaller } from "@uma/core/contracts/common/implementation/MultiCaller.sol";
import { Lockable } from "./Lockable.sol";
import { V3SpokePoolInterface } from "./interfaces/V3SpokePoolInterface.sol";
import { IERC20Auth } from "./external/interfaces/IERC20Auth.sol";
import { WETH9Interface } from "./external/interfaces/WETH9Interface.sol";

/**
 * @title SpokePoolV3Periphery
 * @notice Contract for performing more complex interactions with an Across spoke pool deployment.
 * @dev Variables which may be immutable are not marked as immutable, nor defined in the constructor, so that this
 * contract may be deployed deterministically at the same address across different networks.
 * @custom:security-contact bugs@across.to
 */
contract SpokePoolV3Periphery is Ownable, Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // This contract performs a low level call with arbirary data to an external contract. This is a large attack
    // surface and we should whitelist which function selectors are allowed to be called on which exchange.
    mapping(address => mapping(bytes4 => bool)) public allowedSelectors;

    struct WhitelistedExchanges {
        address exchange;
        bytes4[] allowedSelectors;
        bool[] enabled;
    }

    // Across SpokePool we'll submit deposits to with acrossInputToken as the input token.
    V3SpokePoolInterface public spokePool;

    // Wrapped native token contract address.
    WETH9Interface public wrappedNativeToken;

    // Boolean indicating whether the contract is initialized.
    bool private initialized;

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

    event SwapBeforeBridge(
        address exchange,
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
    error InvalidFunctionSelector();
    error ContractInitialized();
    error InvalidMsgValue();
    error InvalidSpokePool();
    error InvalidSwapToken();
    error InvalidExchange();
    error InvalidExchangeData();

    /**
     * @notice Construct a new SwapAndBridgeBase contract.
     * @dev Is empty and all of the state variables are initialized in the initialize function
     * to allow for deployment at a deterministic address via create2, which requires that the bytecode
     * across different networks is the same. Constructor parameters affect the bytecode so we can only
     * add parameters here that are consistent across networks.
     */
    constructor() {}

    /**
     * @notice Initializes the SwapAndBridgeBase contract.
     * @dev Only the owner can call this function.
     * @param _spokePool Address of the SpokePool contract that we'll submit deposits to.
     * @param _wrappedNativeToken Address of the wrapped native token for the network this contract is deployed to.
     * @param exchanges Array of exchange addresses and their allowed function selectors.
     * @dev These values are initialized in a function and not in the constructor so that the creation code of this contract
     * is the same across networks with different addresses for the wrapped native token and this network's
     * corresponding spoke pool contract. This is to allow this contract to be deterministically deployed with CREATE2.
     */
    function initialize(
        V3SpokePoolInterface _spokePool,
        WETH9Interface _wrappedNativeToken,
        WhitelistedExchanges[] calldata exchanges
    ) external nonReentrant onlyOwner {
        if (initialized) revert ContractInitialized();
        initialized = true;

        if (!address(_spokePool).isContract()) revert InvalidSpokePool();
        spokePool = _spokePool;
        wrappedNativeToken = _wrappedNativeToken;
        _whitelistExchanges(exchanges);
    }

    /**
     * @notice Whitelists exchanges and their allowed function selectors. Can also be used to disable exchanges.
     * @dev Only the owner can call this function.
     * @param exchanges Array of exchange addresses and their allowed function selectors and an enable flag.
     */
    function whitelistExchanges(WhitelistedExchanges[] calldata exchanges) public nonReentrant onlyOwner {
        _whitelistExchanges(exchanges);
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
     * @dev If swapToken or acrossInputToken are the native token for this chain then this function might fail.
     * the assumption is that this function will handle only ERC20 tokens.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     */
    function swapAndBridge(
        IERC20 swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData
    ) external payable nonReentrant {
        // If a user performs a swapAndBridge with the swap token as the native token, wrap the value and treat the rest of transaction
        // as though the user deposited a wrapped native token.
        if (msg.value != 0) {
            if (msg.value != swapTokenAmount) revert InvalidMsgValue();
            if (address(swapToken) != address(wrappedNativeToken)) revert InvalidSwapToken();
            wrappedNativeToken.deposit{ value: msg.value }();
        } else {
            swapToken.safeTransferFrom(msg.sender, address(this), swapTokenAmount);
        }
        _swapAndBridge(
            exchange,
            routerCalldata,
            swapTokenAmount,
            minExpectedInputTokenAmount,
            depositData,
            swapToken,
            acrossInputToken
        );
    }

    /**
     * @notice Swaps an EIP-2612 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param deadline Deadline before which the permit signature is valid.
     * @param v v of the permit signature.
     * @param r r of the permit signature.
     * @param s s of the permit signature.
     */
    function swapAndBridgeWithPermit(
        IERC20Permit swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        IERC20 _swapToken = IERC20(address(swapToken)); // Cast IERC20Permit to IERC20.
        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try swapToken.permit(msg.sender, address(this), swapTokenAmount, deadline, v, r, s) {} catch {}

        _swapToken.safeTransferFrom(msg.sender, address(this), swapTokenAmount);
        _swapAndBridge(
            exchange,
            routerCalldata,
            swapTokenAmount,
            minExpectedInputTokenAmount,
            depositData,
            _swapToken,
            acrossInputToken
        );
    }

    /**
     * @notice Swaps an EIP-3009 token on this chain via specified router before submitting Across deposit atomically.
     * Caller can specify their slippage tolerance for the swap and Across deposit params.
     * @dev If swapToken does not implement `receiveWithAuthorization` to the specifications of EIP-3009, this call will revert.
     * @param swapToken Address of the token that will be swapped for acrossInputToken.
     * @param acrossInputToken Address of the token that will be bridged via Across as the inputToken.
     * @param exchange Address of the exchange contract to call.
     * @param routerCalldata ABI encoded function data to call on router. Should form a swap of swapToken for
     * enough of acrossInputToken, otherwise this function will revert.
     * @param swapTokenAmount Amount of swapToken to swap for a minimum amount of depositData.inputToken.
     * @param minExpectedInputTokenAmount Minimum amount of received depositData.inputToken that we'll submit bridge
     * deposit with.
     * @param depositData Specifies the Across deposit params we'll send after the swap.
     * @param validAfter The unix time after which the `receiveWithAuthorization` signature is valid.
     * @param validBefore The unix time before which the `receiveWithAuthorization` signature is valid.
     * @param nonce Unique nonce used in the `receiveWithAuthorization` signature.
     * @param v v of the EIP-3009 signature.
     * @param r r of the EIP-3009 signature.
     * @param s s of the EIP-3009 signature.
     */
    function swapAndBridgeWithAuthorization(
        IERC20Auth swapToken,
        IERC20 acrossInputToken,
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // While any contract can vacuously implement `transferWithAuthorization` (or just have a fallback),
        // if tokens were not sent to this contract, by this call to the swapToken, the call to `transferFrom`
        // in _swapAndBridge will revert.
        swapToken.receiveWithAuthorization(
            msg.sender,
            address(this),
            swapTokenAmount,
            validAfter,
            validBefore,
            nonce,
            v,
            r,
            s
        );
        IERC20 _swapToken = IERC20(address(swapToken)); // Cast IERC20Auth to IERC20.

        _swapAndBridge(
            exchange,
            routerCalldata,
            swapTokenAmount,
            minExpectedInputTokenAmount,
            depositData,
            _swapToken,
            acrossInputToken
        );
    }

    /**
     * @notice Deposits an EIP-2612 token Across input token into the Spoke Pool contract.
     * @dev If `acrossInputToken` does not implement `permit` to the specifications of EIP-2612, this function will fail.
     * @param acrossInputToken EIP-2612 compliant token to deposit.
     * @param acrossInputAmount Amount of the input token to deposit.
     * @param depositData Specifies the Across deposit params to send.
     * @param deadline Deadline before which the permit signature is valid.
     * @param v v of the permit signature.
     * @param r r of the permit signature.
     * @param s s of the permit signature.
     */
    function depositWithPermit(
        IERC20Permit acrossInputToken,
        uint256 acrossInputAmount,
        DepositData calldata depositData,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        IERC20 _acrossInputToken = IERC20(address(acrossInputToken)); // Cast IERC20Permit to an IERC20 type.
        // For permit transactions, we wrap the call in a try/catch block so that the transaction will continue even if the call to
        // permit fails. For example, this may be useful if the permit signature, which can be redeemed by anyone, is executed by somebody
        // other than this contract.
        try acrossInputToken.permit(msg.sender, address(this), acrossInputAmount, deadline, v, r, s) {} catch {}

        _acrossInputToken.safeTransferFrom(msg.sender, address(this), acrossInputAmount);
        _depositV3(_acrossInputToken, acrossInputAmount, depositData);
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
     * @param v v of the EIP-3009 signature.
     * @param r r of the EIP-3009 signature.
     * @param s s of the EIP-3009 signature.
     */
    function depositWithAuthorization(
        IERC20Auth acrossInputToken,
        uint256 acrossInputAmount,
        DepositData calldata depositData,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
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
        IERC20 _acrossInputToken = IERC20(address(acrossInputToken)); // Cast the input token to an IERC20.
        _depositV3(_acrossInputToken, acrossInputAmount, depositData);
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
        _acrossInputToken.safeIncreaseAllowance(address(spokePool), _acrossInputAmount);
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
        address exchange,
        bytes calldata routerCalldata,
        uint256 swapTokenAmount,
        uint256 minExpectedInputTokenAmount,
        DepositData calldata depositData,
        IERC20 _swapToken,
        IERC20 _acrossInputToken
    ) private {
        // Note: this check should never be impactful, but is here out of an abundance of caution.
        // For example, if the exchange address in the contract is also an ERC20 token that is approved by some
        // user on this contract, a malicious actor could call transferFrom to steal the user's tokens.
        if (!allowedSelectors[exchange][bytes4(routerCalldata)]) revert InvalidFunctionSelector();

        // Swap and run safety checks.
        uint256 srcBalanceBefore = _swapToken.balanceOf(address(this));
        uint256 dstBalanceBefore = _acrossInputToken.balanceOf(address(this));

        _swapToken.safeIncreaseAllowance(exchange, swapTokenAmount);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory result) = exchange.call(routerCalldata);
        require(success, string(result));

        _checkSwapOutputAndDeposit(
            exchange,
            swapTokenAmount,
            srcBalanceBefore,
            dstBalanceBefore,
            minExpectedInputTokenAmount,
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

    function _whitelistExchanges(WhitelistedExchanges[] calldata exchanges) internal {
        uint256 nExchanges = exchanges.length;
        for (uint256 i = 0; i < nExchanges; i++) {
            WhitelistedExchanges memory _exchange = exchanges[i];
            if (!_exchange.exchange.isContract()) revert InvalidExchange();
            uint256 nSelectors = _exchange.allowedSelectors.length;
            if (_exchange.enabled.length != nSelectors) revert InvalidExchangeData();
            for (uint256 j = 0; j < nSelectors; j++) {
                bytes4 selector = _exchange.allowedSelectors[j];
                allowedSelectors[_exchange.exchange][selector] = _exchange.enabled[j];
            }
        }
    }
}
