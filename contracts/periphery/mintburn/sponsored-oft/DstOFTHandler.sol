// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.23;

import { ILayerZeroComposer } from "../../../external/interfaces/ILayerZeroComposer.sol";
import { OFTComposeMsgCodec } from "../../../libraries/OFTComposeMsgCodec.sol";
import { DonationBox } from "../../../chain-adapters/DonationBox.sol";
import { HyperCoreLib } from "../../../libraries/HyperCoreLib.sol";
import { ComposeMsgCodec } from "./ComposeMsgCodec.sol";
import { Bytes32ToAddress } from "../../../libraries/AddressConverters.sol";
import { IOFT } from "../../../interfaces/IOFT.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Contract to hold funds for swaps. We have one SwapHandler per finalToken. Used for separation of funds for different
// flows
contract SwapHandler {
    address public immutable parentHandler;

    constructor() {
        parentHandler = msg.sender;
    }

    modifier onlyParentHandler() {
        require(msg.sender == parentHandler, "Not parent handler");
        _;
    }

    /**
     * @notice Submit a limit order on HyperCore from this SwapHandler's Core address.
     */
    function submitLimitOrder(
        uint32 assetIndex,
        bool isBuy,
        uint64 limitPriceX1e8,
        uint64 sizeX1e8,
        bool reduceOnly,
        HyperCoreLib.Tif tif,
        uint128 cloid
    ) external onlyParentHandler {
        HyperCoreLib.submitLimitOrder(assetIndex, isBuy, limitPriceX1e8, sizeX1e8, reduceOnly, tif, cloid);
    }

    /**
     * @notice Return `amountCore` of `tokenCoreIndex` from this SwapHandler's Core address to parent handler on Core.
     */
    function returnFinalTokenToParent(uint64 tokenCoreIndex, uint64 amountCore) external onlyParentHandler {
        HyperCoreLib.transferERC20CoreToCore(tokenCoreIndex, parentHandler, amountCore);
    }
}

contract DstOFTHandler is ILayerZeroComposer, AccessControl {
    using ComposeMsgCodec for bytes;
    using Bytes32ToAddress for bytes32;

    // Roles
    bytes32 public constant LIMIT_ORDER_UPDATER_ROLE = keccak256("LIMIT_ORDER_UPDATER_ROLE");

    address public immutable endpoint;
    address public immutable oft;
    address public immutable oftToken;

    // TODO: if finalToken of a TX cannot be used as a fee token for account creation, use this tokens
    // TODO: make settable
    address public fallbackSponsorshipToken;
    // @dev Only these tokens are allowed to be a finalToken of the swap flow
    mapping(address => bool) public registeredFinalTokens;

    // @dev `donationBox` holds the funds we use for sponsorship. It serves as a convenient separator for user funds /
    // sponsorship funds
    DonationBox public immutable donationBox;

    // TODO? Is this the best way to authorize an OFT transfer?
    // TODO: currently, one per src chain. Is that fine?
    // @dev This will only work for EVM senders. We don't support SVM senders for OFT at this point
    mapping(uint64 => address) authorizedSrcPeripheryContracts;

    mapping(bytes32 => bool) quoteNonces;

    struct TokenInfo {
        HyperCoreLib.TokenInfo tokenInfo;
        uint32 hCoreTokenIndex;
        bool canBeUsedForAccountCreationFee;
        uint256 accountCreationAmount; // @dev in EVM wei
    }

    // @dev evmTokenAddress => TokenInfo
    mapping(address => TokenInfo) tokens;

    // @dev finalTokenEvmAddress => swapHandler. Used to isolate swap actions to different accounts
    mapping(address => SwapHandler) swapHandlers;

    // Per-finalToken HyperCore market params against `oftToken`
    struct MarketParams {
        uint32 assetIndexAgainstOft;
        bool isBuyAgainstOft;
    }
    mapping(address => MarketParams) public marketParamsByFinalToken;

    // Pending swap queue per final token (FCFS)
    struct PendingSwap {
        address user;
        address finalToken;
        uint256 amountInEVM; // amount of `oftToken` bridged for this order (EVM units)
        uint64 minOutCore; // minimum final token amount on Core required to settle
        uint128 cloid; // client order id associated with the placed limit order
    }

    // quoteNonce => pending swap details
    mapping(bytes32 => PendingSwap) public pendingSwaps;
    // finalToken => queue of quote nonces
    mapping(address => bytes32[]) public pendingQueue;
    // finalToken => current head index in queue
    mapping(address => uint256) public pendingQueueHead;

    error AuthorizedPeripheryNotSet(uint32 _srcEid);

    event FallbackSponsorshipTokenSet(address evmTokenAddress);
    event FinalTokenRegistered(address evmTokenAddress);
    event SwapHandlerDeployed(address finalToken, address handler);
    event SimpleHcoreTransfer(
        bytes32 quoteNonce,
        uint256 amount,
        uint256 sponsoredAmount,
        address finalUser,
        address finalToken
    );
    event DonationBoxInsufficientFunds(address token, uint256 requested);
    event PendingSwapEnqueued(
        bytes32 quoteNonce,
        address user,
        address finalToken,
        uint256 amountInEVM,
        uint64 minOutCore
    );
    event LimitOrderSubmitted(bytes32 quoteNonce, uint64 limitPriceX1e8, uint64 sizeX1e8);
    event SwapFinalized(bytes32 quoteNonce, uint64 amountCore, address user, address finalToken);
    event MarketParamsUpdated(address finalToken, uint32 assetIndexAgainstOft, bool isBuyAgainstOft);

    // TODO: on construction, we should populate the `tokens` mapping with at least info about the USDT0
    // TODO: then we should have a function like `addAuthorizedFinalToken` that will add a token to the tokens
    constructor(
        address _endpoint,
        address _oft,
        address _oftToken,
        uint32 _oftTokenHCoreId,
        bool _canBeUsedForAccountCreationFee,
        uint256 _sponsorAmountWei
    ) {
        require(_oftToken == IOFT(_oft).token(), "oft, oftToken mistmatch");

        HyperCoreLib.TokenInfo memory tokenInfo = _getTokenInfoChecked(_oftToken, _oftTokenHCoreId);
        tokens[_oftToken] = TokenInfo(tokenInfo, _oftTokenHCoreId, _canBeUsedForAccountCreationFee, _sponsorAmountWei);

        endpoint = _endpoint;
        oft = _oft;
        oftToken = _oftToken;
        donationBox = new DonationBox();

        // AccessControl setup
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setRoleAdmin(LIMIT_ORDER_UPDATER_ROLE, DEFAULT_ADMIN_ROLE);
    }

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not default admin");
        _;
    }

    modifier onlyExistingToken(address evmTokenAddress) {
        // TODO: does this work?
        require(tokens[evmTokenAddress].tokenInfo.evmContract != address(0), "Unknown token");
        _;
    }

    function updateTokenInfo(
        address evmTokenAddress,
        uint32 hCoreTokenIndex,
        bool canBeUsedForAccountCreationFee,
        uint256 sponsorAmountWei
    ) external onlyDefaultAdmin {
        _updateTokenInfo(evmTokenAddress, hCoreTokenIndex, canBeUsedForAccountCreationFee, sponsorAmountWei);
    }

    function setFallbackSponsorshipToken(
        address evmTokenAddress
    ) external onlyDefaultAdmin onlyExistingToken(evmTokenAddress) {
        require(tokens[evmTokenAddress].canBeUsedForAccountCreationFee, "canBeUsedForAccountCreationFee = false");
        fallbackSponsorshipToken = evmTokenAddress;
    }

    // @dev config admin calls this function to add support for an additional token that can be a final token of swap flow
    function registerNewFinalToken(
        address evmTokenAddress,
        uint32 assetIndexAgainstOft,
        bool isBuyAgainstOft
    ) external onlyDefaultAdmin onlyExistingToken(evmTokenAddress) {
        // TODO: there has to be some unregister call too. But we then have to have the ability to withdraw all tokens form the SwapHandler ...
        require(registeredFinalTokens[evmTokenAddress] == false, "Already registered");
        // Create a new SwapHandler contract for this final token
        SwapHandler handler = new SwapHandler();
        swapHandlers[evmTokenAddress] = handler;
        emit SwapHandlerDeployed(evmTokenAddress, address(handler));
        registeredFinalTokens[evmTokenAddress] = true;
        marketParamsByFinalToken[evmTokenAddress] = MarketParams({
            assetIndexAgainstOft: assetIndexAgainstOft,
            isBuyAgainstOft: isBuyAgainstOft
        });
        emit MarketParamsUpdated(evmTokenAddress, assetIndexAgainstOft, isBuyAgainstOft);
        emit FinalTokenRegistered(evmTokenAddress);

        // Pre-initialize SwapHandler Core account by sending a small amount from DonationBox to the handler on Core.
        uint256 initAmountWei = tokens[evmTokenAddress].accountCreationAmount;
        if (initAmountWei > 0) {
            try donationBox.withdraw(IERC20(tokens[evmTokenAddress].tokenInfo.evmContract), initAmountWei) {
                // Bridge to the SwapHandler Core account
                HyperCoreLib.transferERC20EVMToCore(
                    tokens[evmTokenAddress].tokenInfo.evmContract,
                    tokens[evmTokenAddress].hCoreTokenIndex,
                    address(handler),
                    initAmountWei,
                    tokens[evmTokenAddress].tokenInfo.evmExtraWeiDecimals
                );
            } catch {
                revert("DonationBoxInsufficientFunds");
            }
        }
    }

    /**
     * @notice Handles incoming composed messages from LayerZero.
     * @dev Ensures the message comes from the correct OApp and is sent through the authorized endpoint.
     *
     * @param _oApp The address of the OApp that is sending the composed message.
     */
    function lzCompose(
        address _oApp,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override {
        require(_oApp == oft, "ComposedReceiver: Invalid OApp");
        require(msg.sender == endpoint, "ComposedReceiver: Unauthorized sender");
        _requireAuthorizedPeriphery(_message);

        // Decode the actual `composeMsg` payload to extract the recipient address
        bytes memory _composeMsg = OFTComposeMsgCodec.composeMsg(_message);

        // TODO: here, we could limit admin's powers by recording the amount as `unclaimedAmount` and only allowing the
        // admin to withdraw up to that amount. Nice-to-have IMO but not a req.
        // @dev If `_composeMsg` is not formatted the way we expect, just revert this call instead of potentially
        // blackholing the money. If the funds landed into this Handler, they'll have to be rescued via _adminRescueERC20()
        require(_composeMsg._isValidComposeMsgBytelength(), "_composeMsg incorrectly formatted");

        bytes32 quoteNonce = _composeMsg._getNonce();
        require(!quoteNonces[quoteNonce], "Nonce already used");
        quoteNonces[quoteNonce] = true;

        address finalRecipient = _composeMsg._getFinalRecipient().toAddress();
        address finalToken = _composeMsg._getFinalToken().toAddress();
        uint256 maxBpsToSponsor = _composeMsg._getMaxBpsToSponsor();
        uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);
        if (finalToken == oftToken) {
            _executeSimpleHCoreTransferFlow(_amountLD, quoteNonce, maxBpsToSponsor, finalRecipient, finalToken);
        } else {
            _initializeSwapFlow(_amountLD, quoteNonce, finalRecipient, finalToken);
        }
    }

    function _executeSimpleHCoreTransferFlow(
        uint256 amountLD,
        bytes32 quoteNonce,
        uint256 maxBpsToSponsor,
        address finalUser,
        address finalToken
    ) internal {
        TokenInfo memory oftTokenInfo = tokens[oftToken];

        bool userHasHCoreAccount = HyperCoreLib.coreUserExists(finalUser);

        // TODO? Consider including fallbackSponsorshipToken logic in here. We'd need to send the 1 of fallback token
        // first and then the next transfer second: it's unclear whether or not HCore would respect submission order
        uint256 amountToSponsor = 0;
        // @dev If we're able to sponsor the user account creation in the `oftToken` and the account creation fee is
        // less than max fee we're willing to pay, sponsor account creation
        if (!userHasHCoreAccount && oftTokenInfo.canBeUsedForAccountCreationFee) {
            uint256 maxAmtToSponsor = (amountLD * maxBpsToSponsor) / 10_000;
            uint256 sponsorAmtRequired = oftTokenInfo.accountCreationAmount;
            if (maxAmtToSponsor <= sponsorAmtRequired) {
                amountToSponsor = sponsorAmtRequired;
            }
            // Try to pull entire sponsored amount from donation box. If it fails, sponsor none.
            if (amountToSponsor != 0) {
                try donationBox.withdraw(IERC20(oftTokenInfo.tokenInfo.evmContract), amountToSponsor) {
                    // success: full sponsorship amount withdrawn to this contract
                } catch {
                    emit DonationBoxInsufficientFunds(oftTokenInfo.tokenInfo.evmContract, amountToSponsor);
                    amountToSponsor = 0;
                }
            }
        }

        HyperCoreLib.transferERC20EVMToCore(
            oftTokenInfo.tokenInfo.evmContract,
            oftTokenInfo.hCoreTokenIndex,
            finalUser,
            amountLD + amountToSponsor,
            oftTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        emit SimpleHcoreTransfer(quoteNonce, amountLD, amountToSponsor, finalUser, finalToken);
    }

    function _initializeSwapFlow(uint256 amountLD, bytes32 quoteNonce, address finalUser, address finalToken) internal {
        require(registeredFinalTokens[finalToken], "Final token not registered");
        require(address(swapHandlers[finalToken]) != address(0), "No SwapHandler");

        // Bridge the OFT tokens from this contract on HyperEVM to the SwapHandler on HyperCore
        TokenInfo memory oftTokenInfo = tokens[oftToken];
        HyperCoreLib.transferERC20EVMToCore(
            oftTokenInfo.tokenInfo.evmContract,
            oftTokenInfo.hCoreTokenIndex,
            address(swapHandlers[finalToken]),
            amountLD,
            oftTokenInfo.tokenInfo.evmExtraWeiDecimals
        );

        // TODO! Compute this based on the LimitOrder price we're about to submit + HyperLiquid Market pair fees. Can we load these fees on demand?
        // TODO! We can't really have incorrect values here .. If we do, we might never be able to settle some user orders until we top up
        // TODO! the swap handler by admin action probably _AND_ update the market params by hand. Hopium that 1.4 bps will not change anytime soon
        uint64 minOutCore = HyperCoreLib.convertEvmToCoreNoBridge(
            amountLD,
            tokens[finalToken].tokenInfo.evmExtraWeiDecimals
        );

        // Enqueue pending swap with computed minOutCore
        pendingSwaps[quoteNonce] = PendingSwap({
            user: finalUser,
            finalToken: finalToken,
            amountInEVM: amountLD,
            minOutCore: minOutCore,
            cloid: 0
        });
        pendingQueue[finalToken].push(quoteNonce);
        emit PendingSwapEnqueued(quoteNonce, finalUser, finalToken, amountLD, minOutCore);

        // Submit a placeholder limit order on behalf of the SwapHandler (price=1.0, GTC)
        MarketParams memory mp = marketParamsByFinalToken[finalToken];
        require(mp.assetIndexAgainstOft != 0, "Market params unset");
        SwapHandler handler = swapHandlers[finalToken];
        uint64 limitPriceX1e8 = 1e8; // 1.0
        uint64 sizeX1e8 = minOutCore; // MVP approximation
        handler.submitLimitOrder(
            mp.assetIndexAgainstOft,
            mp.isBuyAgainstOft,
            limitPriceX1e8,
            sizeX1e8,
            false,
            HyperCoreLib.Tif.GTC,
            0
        );
        emit LimitOrderSubmitted(quoteNonce, limitPriceX1e8, sizeX1e8);
    }

    // TODO: trusted actor can cancel+replace existing limit orders per CLOID.

    /**
     * @notice FCFS settlement: transfers finalToken from SwapHandler on Core to users when sufficient balance exists.
     * @param finalToken The EVM address of the final token for which to settle the queue.
     * @param maxToProcess Max number of orders to try to settle in this call (gas guard).
     */
    function finalizePendingUserSwaps(address finalToken, uint256 maxToProcess) external {
        require(registeredFinalTokens[finalToken], "Final token not registered");
        TokenInfo memory finalTokenInfo = tokens[finalToken];
        SwapHandler handler = swapHandlers[finalToken];
        require(address(handler) != address(0), "No SwapHandler");

        uint256 head = pendingQueueHead[finalToken];
        bytes32[] storage queue = pendingQueue[finalToken];
        if (head >= queue.length || maxToProcess == 0) return;

        // Note: `availableCore` is the SwapHandler's Core balance for `finalToken`, which monotonically increases
        uint64 availableCore = HyperCoreLib.spotBalance(address(handler), finalTokenInfo.hCoreTokenIndex);
        uint256 processed = 0;

        while (head < queue.length && processed < maxToProcess) {
            bytes32 nonce = queue[head];
            PendingSwap storage ps = pendingSwaps[nonce];
            if (availableCore < ps.minOutCore) {
                break;
            }

            // 1) Pull tokens back from SwapHandler to parent handler on Core
            handler.returnFinalTokenToParent(finalTokenInfo.hCoreTokenIndex, ps.minOutCore);

            // 2) Top up 1:1 from DonationBox on EVM to parent handler on Core (best-effort)
            uint256 topUpEvmAmount = HyperCoreLib.convertCoreToEvmCeil(
                ps.minOutCore,
                finalTokenInfo.tokenInfo.evmExtraWeiDecimals
            );
            if (topUpEvmAmount > 0) {
                try donationBox.withdraw(IERC20(finalTokenInfo.tokenInfo.evmContract), topUpEvmAmount) {
                    HyperCoreLib.transferERC20EVMToCore(
                        finalTokenInfo.tokenInfo.evmContract,
                        finalTokenInfo.hCoreTokenIndex,
                        address(this),
                        topUpEvmAmount,
                        finalTokenInfo.tokenInfo.evmExtraWeiDecimals
                    );
                } catch {
                    emit DonationBoxInsufficientFunds(finalTokenInfo.tokenInfo.evmContract, topUpEvmAmount);
                }
            }

            // 3) Send the full amount to the user on Core from the parent handler
            HyperCoreLib.transferERC20CoreToCore(finalTokenInfo.hCoreTokenIndex, ps.user, ps.minOutCore);

            emit SwapFinalized(nonce, ps.minOutCore, ps.user, ps.finalToken);

            availableCore -= ps.minOutCore;

            // Pop from queue
            delete pendingSwaps[nonce];
            head += 1;
            processed += 1;
        }

        // Advance head and compact array if we've exhausted a large prefix
        if (head != pendingQueueHead[finalToken]) {
            pendingQueueHead[finalToken] = head;
        }

        // No truncation/compaction: we keep the queue as [head, queue.length)
    }

    // @dev Checks that _message came from the authorized src periphery contract stored in `authorizedSrcPeripheryContracts`
    function _requireAuthorizedPeriphery(bytes calldata _message) internal view {
        // Decode the source endpoint ID (originating chain)
        uint32 _srcEid = OFTComposeMsgCodec.srcEid(_message);
        address authorizedPeriphery = authorizedSrcPeripheryContracts[_srcEid];
        if (authorizedPeriphery == address(0)) {
            revert AuthorizedPeripheryNotSet(_srcEid);
        }

        // Decode the `composeFrom` address (original sender) from bytes32 to address
        bytes32 _composeFromBytes = OFTComposeMsgCodec.composeFrom(_message);

        // @dev This will only work for EVM senders. We don't support SVM senders for OFT at this point
        address _composeFrom = OFTComposeMsgCodec.bytes32ToAddress(_composeFromBytes);
        // @dev If the message is not from the authorized periphery contract, we cannot ensure the shape of _composeMsg
        // @dev _composeMsg is where the `finalRecipient` resides. These funds have to be rescued via _adminRescueERC20()
        require(authorizedPeriphery == _composeFrom, "Src periphery not authorized");
    }

    // Internal functions

    function _updateTokenInfo(
        address evmTokenAddress,
        uint32 hCoreTokenIndex,
        bool canBeUsedForAccountCreationFee,
        uint256 sponsorAmountWei
    ) internal {
        HyperCoreLib.TokenInfo memory tokenInfo = _getTokenInfoChecked(evmTokenAddress, hCoreTokenIndex);
        tokens[evmTokenAddress] = TokenInfo(
            tokenInfo,
            hCoreTokenIndex,
            canBeUsedForAccountCreationFee,
            sponsorAmountWei
        );
        // @dev if we're updating token info for a current `fallbackSponsorshipToken`, make sure that `canBeUsedForAccountCreationFee`
        // stays true. Otherwise, unset `fallbackSponsorshipToken`
        if (evmTokenAddress == fallbackSponsorshipToken && !tokens[evmTokenAddress].canBeUsedForAccountCreationFee) {
            fallbackSponsorshipToken = address(0);
        }
    }

    /**
     * @notice Set per-token trading params for swapping against `oftToken` on HyperCore.
     */
    function updateTokenTradingParams(
        address evmTokenAddress,
        uint32 marketAssetIndexAgainstOft,
        bool isBuyAgainstOft
    ) external onlyDefaultAdmin onlyExistingToken(evmTokenAddress) {
        marketParamsByFinalToken[evmTokenAddress] = MarketParams({
            assetIndexAgainstOft: marketAssetIndexAgainstOft,
            isBuyAgainstOft: isBuyAgainstOft
        });
        emit MarketParamsUpdated(evmTokenAddress, marketAssetIndexAgainstOft, isBuyAgainstOft);
    }

    function _getTokenInfoChecked(
        address evmTokenAddress,
        uint32 hcoreTokenIndex
    ) internal view returns (HyperCoreLib.TokenInfo memory tokenInfo) {
        tokenInfo = HyperCoreLib.tokenInfo(hcoreTokenIndex);
        require(tokenInfo.evmContract == evmTokenAddress, "Wrong token id");
    }
}
