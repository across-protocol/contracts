// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "../interfaces/SpokePoolMessageHandler.sol";
import "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-v4/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-v4/security/ReentrancyGuard.sol";
import { ECDSA } from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
import { HyperCoreLib } from "../libraries/HyperCoreLib.sol";
import { Ownable } from "@openzeppelin/contracts-v4/access/Ownable.sol";
import { DonationBox } from "../chain-adapters/DonationBox.sol";
import { CoreTokenInfo, CoreTokenInfoLib } from "../periphery/mintburn/Structs.sol";

/**
 * @title Allows caller to bridge tokens from HyperEVM to Hypercore and send them to an end user's account
 * on Hypercore.
 * @dev This contract should only be deployed on HyperEVM.
 * @dev This contract can replace a MulticallHandler on HyperEVM if the intent only wants to deposit tokens into
 * Hypercore and bypass the other complex arbitrary calldata logic.
 * @dev This contract can also be called directly to deposit tokens into Hypercore on behalf of an end user.
 */
contract HyperliquidDepositHandler is AcrossMessageHandler, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Stores hardcoded Hypercore configurations for tokens that this handler supports.
    mapping(address => CoreTokenInfo) public supportedTokens;

    // Donation box contract to store funds for account activation fees.
    DonationBox public immutable donationBox;

    // Address of the signer that will sign the payloads used for calling handleV3AcrossMessage. This signer
    // should be one controlled by the Across API to prevent griefing attacks that attempt to drain the Donation Box.
    address public signer;

    // Address of the SpokePool contract that can call handleV3AcrossMessage.
    address public spokePool;

    // Track which accounts we have already sponsored for activation. Used to prevent griefing attacks when the same account is activated multiple times
    // due to Hyperliquid's policy of removing dust from small accounts which technically could be taken advantage of by a griefer.
    mapping(address => bool) public accountsActivated;

    error InsufficientEvmAmountForActivation();
    error TokenNotSupported();
    error InvalidSignature();
    error NotSpokePool();
    error AccountAlreadyActivated();
    error CannotActivateAccount();
    error UnknownAccountActivationMode();
    error TokenCannotBeUsedForAccountActivation();

    enum AccountActivationMode {
        None, // 0: No activation expected/needed (revert if user doesn't exist)
        FromUserFunds, // 1: Activate from user's deposit if needed (no signature required)
        FromDonationBox // 2: Activate from DonationBox if needed (signature required)
    }

    event DepositToHypercore(
        address indexed user,
        address indexed token,
        uint64 userCoreAmount,
        uint64 activationFeePaid,
        uint64 activationFeeSponsored
    );
    event FallbackToHyperEVM(address indexed user, address indexed token, uint256 evmAmount);
    event AddedSupportedToken(address evmAddress, uint64 tokenId, uint256 activationFeeEvm, int8 decimalDiff);
    event SignerSet(address signer);
    event SpokePoolSet(address spokePool);

    /**
     * @notice Constructor.
     * @dev Creates a new donation box contract owned by this contract.
     * @param _signer Address of the signer that will sign the payloads used for calling handleV3AcrossMessage. This signer
     * should be one controlled by the Across API to prevent griefing attacks that attempt to drain the Donation Box.
     * @param _spokePool Address of the SpokePool contract that can call handleV3AcrossMessage.
     */
    constructor(address _signer, address _spokePool) {
        donationBox = new DonationBox();
        signer = _signer;
        spokePool = _spokePool;
    }

    modifier onlySpokePool() {
        if (msg.sender != spokePool) revert NotSpokePool();
        _;
    }

    /// -------------------------------------------------------------------------------------------------------------
    /// - PUBLIC FUNCTIONS -
    /// -------------------------------------------------------------------------------------------------------------

    /**
     * @notice Bridges tokens from HyperEVM to Hypercore and sends them to the end user's account on Hypercore.
     * @dev Requires msg.sender to have approved this contract to spend the tokens.
     * @param token The address of the token to deposit.
     * @param amount The amount of tokens on HyperEVM to deposit.
     * @param message The first byte selects the AccountActivationMode:
     * - 0 (None): No activation expected. Remainder is abi.encode(user, destinationDex). Reverts if user doesn't exist.
     * - 1 (FromUserFunds): Activate from user's deposit if needed. Remainder is abi.encode(user, destinationDex). No signature required.
     * - 2 (FromDonationBox): Activate from DonationBox if needed. Remainder is abi.encode(user, destinationDex, signature).
     *   Signature must be from the authorized signer (Across API) to prevent griefing attacks on the DonationBox.
     */
    function depositToHypercore(address token, uint256 amount, bytes calldata message) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _decodeMessageAndDepositToHypercore(token, amount, message);
    }

    /**
     * @notice Entrypoint function if this contract is called by the SpokePool contract following an intent fill.
     * @dev Deposits tokens into Hypercore and sends them to the end user's account on Hypercore.
     * @dev Requires msg.sender to be the SpokePool contract. This prevents someone from calling this function
     * to drain funds that were accidentally dropped onto this contract.
     * @param token The address of the token sent.
     * @param amount The amount of tokens received by this contract.
     * @param message The first byte selects the AccountActivationMode:
     * - 0 (None): No activation expected. Remainder is abi.encode(user, destinationDex). Reverts if user doesn't exist.
     * - 1 (FromUserFunds): Activate from user's deposit if needed. Remainder is abi.encode(user, destinationDex). No signature required.
     * - 2 (FromDonationBox): Activate from DonationBox if needed. Remainder is abi.encode(user, destinationDex, signature).
     *   Signature must be from the authorized signer (Across API) to prevent griefing attacks on the DonationBox.
     */
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address /* relayer */,
        bytes calldata message
    ) external nonReentrant onlySpokePool {
        _decodeMessageAndDepositToHypercore(token, amount, message);
    }

    function _decodeMessageAndDepositToHypercore(address token, uint256 amount, bytes calldata message) internal {
        AccountActivationMode mode = AccountActivationMode(uint8(message[0]));

        if (mode == AccountActivationMode.None || mode == AccountActivationMode.FromUserFunds) {
            (address user, uint32 destinationDex) = abi.decode(message[1:], (address, uint32));
            _depositToHypercore(token, amount, user, mode, destinationDex);
        } else if (mode == AccountActivationMode.FromDonationBox) {
            (address user, uint32 destinationDex, bytes memory signature) = abi.decode(
                message[1:],
                (address, uint32, bytes)
            );
            _verifySignature(user, signature);
            _depositToHypercore(token, amount, user, mode, destinationDex);
        } else {
            revert UnknownAccountActivationMode();
        }
    }

    /// -------------------------------------------------------------------------------------------------------------
    /// - ONLY OWNER FUNCTIONS -
    /// -------------------------------------------------------------------------------------------------------------

    /**
     * @notice Sets the address of the signer that will sign the payloads used for calling handleV3AcrossMessage.
     * @dev Caller must be owner of this contract.
     * @param _signer Address of the signer that will sign the payloads used for calling handleV3AcrossMessage. This signer
     * should be one controlled by the Across API to prevent griefing attacks that attempt to drain the Donation Box.
     */
    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
        emit SignerSet(signer);
    }

    /**
     * @notice Sets the address of the SpokePool contract that can call handleV3AcrossMessage.
     * @dev Caller must be owner of this contract.
     * @param _spokePool Address of the SpokePool contract that can call handleV3AcrossMessage.
     */
    function setSpokePool(address _spokePool) external onlyOwner {
        spokePool = _spokePool;
        emit SpokePoolSet(spokePool);
    }

    /**
     * @notice Adds a new token to the supported tokens list.
     * @dev Caller must be owner of this contract.
     * @param token The address of the EVM token.
     * @param coreIndex The index of the Hypercore token.
     * @param canBeUsedForAccountActivation Whether this token can be used to pay for account activation.
     * @param accountActivationFeeCore The account activation fee in Core units.
     * @param bridgeSafetyBufferCore Bridge buffer to use when checking safety of bridging evm -> core. In core units.
     */
    function addSupportedToken(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external onlyOwner {
        CoreTokenInfo memory coreTokenInfo = CoreTokenInfoLib.build(
            coreIndex,
            canBeUsedForAccountActivation,
            accountActivationFeeCore,
            bridgeSafetyBufferCore
        );
        supportedTokens[token] = coreTokenInfo;
        emit AddedSupportedToken(
            token,
            coreIndex,
            coreTokenInfo.accountActivationFeeEVM,
            coreTokenInfo.tokenInfo.evmExtraWeiDecimals
        );
    }

    /**
     * @notice Send Hypercore funds to a user from this contract's Hypercore account
     * @dev The coreAmount parameter is specified in Hypercore units which often differs from the EVM units for the
     * same token.
     * @param token The token address
     * @param coreAmount The amount of tokens on Hypercore to sweep
     * @param user The address of the user to send the tokens to
     */
    function sweepCoreFundsToUser(address token, uint64 coreAmount, address user) external onlyOwner nonReentrant {
        uint64 tokenIndex = _getTokenInfo(token).coreIndex;
        HyperCoreLib.transferERC20SpotToSpot(tokenIndex, user, coreAmount);
    }

    /**
     * @notice Send donation box funds to a user from this contract's address on HyperEVM
     * @param token The token address
     * @param amount The amount of tokens to sweep
     * @param user The address of the user to send the tokens to
     */
    function sweepDonationBoxFundsToUser(address token, uint256 amount, address user) external onlyOwner nonReentrant {
        donationBox.withdraw(IERC20(token), amount);
        IERC20(token).safeTransfer(user, amount);
    }

    /**
     * @notice Send ERC20 tokens to a user from this contract's address on HyperEVM
     * @param token The token address
     * @param evmAmount The amount of tokens to sweep
     * @param user The address of the user to send the tokens to
     */
    function sweepERC20ToUser(address token, uint256 evmAmount, address user) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(user, evmAmount);
    }

    /// -------------------------------------------------------------------------------------------------------------
    /// - INTERNAL FUNCTIONS -
    /// -------------------------------------------------------------------------------------------------------------

    function _depositToHypercore(
        address token,
        uint256 evmAmount,
        address user,
        AccountActivationMode mode,
        uint32 destinationDex
    ) internal {
        CoreTokenInfo memory coreTokenInfo = _getTokenInfo(token);
        int8 decimalDiff = coreTokenInfo.tokenInfo.evmExtraWeiDecimals;

        // Check if safe to bridge before any state changes. Use evmAmount (not including potential
        // activation fee) since if bridge is unsafe, we won't be activating anyway.
        (, uint64 quotedCoreAmount) = HyperCoreLib.maximumEVMSendAmountToAmounts(evmAmount, decimalDiff);
        if (
            !HyperCoreLib.isCoreAmountSafeToBridge(
                coreTokenInfo.coreIndex,
                quotedCoreAmount,
                coreTokenInfo.bridgeSafetyBufferCore
            )
        ) {
            // Bridge doesn't have enough liquidity - fall back to HyperEVM transfer
            IERC20(token).safeTransfer(user, evmAmount);
            emit FallbackToHyperEVM(user, token, evmAmount);
            return;
        }

        uint256 totalEvmAmount = evmAmount;
        uint64 accountActivationFeeCore = 0;
        uint64 sponsoredAmount = 0;

        bool userExists = HyperCoreLib.coreUserExists(user);
        if (!userExists) {
            if (mode == AccountActivationMode.None) revert CannotActivateAccount();
            if (!coreTokenInfo.canBeUsedForAccountActivation) revert TokenCannotBeUsedForAccountActivation();
            if (accountsActivated[user]) revert AccountAlreadyActivated();
            accountsActivated[user] = true;
            uint256 activationFee = coreTokenInfo.accountActivationFeeEVM;
            accountActivationFeeCore = coreTokenInfo.accountActivationFeeCore;

            if (mode == AccountActivationMode.FromDonationBox) {
                donationBox.withdraw(IERC20(token), activationFee);
                totalEvmAmount += activationFee;
                sponsoredAmount = accountActivationFeeCore;
            } else {
                (, uint64 depositCore) = HyperCoreLib.maximumEVMSendAmountToAmounts(evmAmount, decimalDiff);
                if (depositCore <= accountActivationFeeCore) revert InsufficientEvmAmountForActivation();
            }
        }

        (, uint64 userAmount) = HyperCoreLib.transferERC20EVMToCore(
            token,
            coreTokenInfo.coreIndex,
            user,
            totalEvmAmount,
            decimalDiff,
            destinationDex,
            accountActivationFeeCore
        );

        emit DepositToHypercore(user, token, userAmount, accountActivationFeeCore, sponsoredAmount);
    }

    function _verifySignature(address expectedUser, bytes memory signature) internal view {
        /// @dev There is no nonce in this signature because an account on Hypercore can only be activated once
        /// by this contract, so reusing a signature cannot be used to grief the DonationBox.
        bytes32 expectedHash = keccak256(abi.encode(expectedUser));
        if (ECDSA.recover(expectedHash, signature) != signer) revert InvalidSignature();
    }

    function _getTokenInfo(address evmAddress) internal view returns (CoreTokenInfo memory) {
        if (supportedTokens[evmAddress].tokenInfo.evmContract == address(0)) {
            revert TokenNotSupported();
        }
        return supportedTokens[evmAddress];
    }

    // Native tokens are not supported by this contract, so there is no fallback function.
}
