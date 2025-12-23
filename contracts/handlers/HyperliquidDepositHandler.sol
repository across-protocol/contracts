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
    struct TokenInfo {
        // HyperEVM token address.
        address evmAddress;
        // Hypercore token index.
        uint64 tokenId;
        // Activation fee in EVM units. e.g. 1000000 ($1) for USDH.
        uint256 activationFeeEvm;
        // coreDecimals - evmDecimals. e.g. -2 for USDH.
        int8 decimalDiff;
    }

    // Stores hardcoded Hypercore configurations for tokens that this handler supports.
    mapping(address => TokenInfo) public supportedTokens;

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

    event UserAccountActivated(address user, address indexed token, uint256 amountRequiredToActivate);
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
     * @param user The address of the user on Hypercore to send the tokens to.
     * @param signature Encoded signed message containing the end user address. The payload is designed to be signed
     * by the Across API to prevent griefing attacks that attempt to drain the Donation Box.
     */
    function depositToHypercore(
        address token,
        uint256 amount,
        address user,
        bytes memory signature
    ) external nonReentrant {
        _verifySignature(user, signature);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _depositToHypercore(token, amount, user);
    }

    /**
     * @notice Entrypoint function if this contract is called by the SpokePool contract following an intent fill.
     * @dev Deposits tokens into Hypercore and sends them to the end user's account on Hypercore.
     * @dev Requires msg.sender to be the SpokePool contract. This prevents someone from calling this function
     * to drain funds that were accidentally dropped onto this contract.
     * @param token The address of the token sent.
     * @param amount The amount of tokens received by this contract.
     * @param message Encoded signed message containing the end user address. The payload is designed to be signed
     * by the Across API to prevent griefing attacks that attempt to drain the Donation Box.
     */
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address /* relayer */,
        bytes memory message
    ) external nonReentrant onlySpokePool {
        (address user, bytes memory signature) = abi.decode(message, (address, bytes));
        _verifySignature(user, signature);
        _depositToHypercore(token, amount, user);
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
     * @param evmAddress The address of the EVM token.
     * @param tokenId The index of the Hypercore token.
     * @param activationFeeEvm The activation fee in EVM units.
     * @param decimalDiff The difference in decimals between the EVM and Hypercore tokens.
     */
    function addSupportedToken(
        address evmAddress,
        uint64 tokenId,
        uint256 activationFeeEvm,
        int8 decimalDiff
    ) external onlyOwner {
        supportedTokens[evmAddress] = TokenInfo({
            evmAddress: evmAddress,
            tokenId: tokenId,
            activationFeeEvm: activationFeeEvm,
            decimalDiff: decimalDiff
        });
        emit AddedSupportedToken(evmAddress, tokenId, activationFeeEvm, decimalDiff);
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
        uint64 tokenIndex = _getTokenInfo(token).tokenId;
        HyperCoreLib.transferERC20CoreToCore(tokenIndex, user, coreAmount);
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

    function _depositToHypercore(address token, uint256 evmAmount, address user) internal {
        TokenInfo memory tokenInfo = _getTokenInfo(token);
        uint64 tokenIndex = tokenInfo.tokenId;
        int8 decimalDiff = tokenInfo.decimalDiff;

        bool userExists = HyperCoreLib.coreUserExists(user);
        if (!userExists) {
            if (accountsActivated[user]) revert AccountAlreadyActivated();
            accountsActivated[user] = true;
            // To activate an account, we must pay the activation fee from this contract's core account and then send 1
            // wei to the user's account, so we pull the activation fee + 1 wei from the donation box. This contract
            // does not allow the end user subtracting part of their received amount to use for the activation fee.
            uint256 activationFee = tokenInfo.activationFeeEvm;
            uint256 amountRequiredToActivate = activationFee + 1;
            donationBox.withdraw(IERC20(token), amountRequiredToActivate);
            // Deposit the activation fee + 1 wei into this contract's core account to pay for the user's
            // account activation.
            HyperCoreLib.transferERC20EVMToSelfOnCore(token, tokenIndex, amountRequiredToActivate, decimalDiff);
            HyperCoreLib.transferERC20CoreToCore(tokenIndex, user, 1);
            emit UserAccountActivated(user, token, amountRequiredToActivate);
        }

        HyperCoreLib.transferERC20EVMToCore(token, tokenIndex, user, evmAmount, decimalDiff);
    }

    function _verifySignature(address expectedUser, bytes memory signature) internal view returns (bool) {
        /// @dev There is no nonce in this signature because an account on Hypercore can only be activated once
        /// by this contract, so reusing a signature cannot be used to grief the DonationBox.
        bytes32 expectedHash = keccak256(abi.encode(expectedUser));
        if (ECDSA.recover(expectedHash, signature) != signer) revert InvalidSignature();
    }

    function _getTokenInfo(address evmAddress) internal view returns (TokenInfo memory) {
        if (supportedTokens[evmAddress].evmAddress == address(0)) {
            revert TokenNotSupported();
        }
        return supportedTokens[evmAddress];
    }

    // Native tokens are not supported by this contract, so there is no fallback function.
}
