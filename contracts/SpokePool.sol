// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./interfaces/WETH9.sol";

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "./Lockable.sol";
import "./MerkleLib.sol";
import "./SpokePoolInterface.sol";

/**
 * @title SpokePool
 * @notice Contract deployed on source and destination chains enabling depositors to transfer assets from source to
 * destination. Deposit orders are fulfilled by off-chain relayers who also interact with this contract. Deposited
 * tokens are locked on the source chain and relayers send the recipient the desired token currency and amount
 * on the destination chain. Locked source chain tokens are later sent over the canonical token bridge to L1.
 * @dev This contract is designed to be deployed to L2's, not mainnet.
 */
abstract contract SpokePool is SpokePoolInterface, Testable, Lockable, MultiCaller {
    using SafeERC20 for IERC20;
    using Address for address;

    // Address of the L1 contract that acts as the owner of this SpokePool.
    address public crossDomainAdmin;

    // Address of the L1 contract that will send tokens to and receive tokens from this contract.
    address public hubPool;

    // Address of WETH contract for this network. If an origin token matches this, then the caller can optionally
    // instruct this contract to wrap ETH when depositing.
    WETH9 public weth;

    // Timestamp when contract was constructed. Relays cannot have a quote time before this.
    uint32 public deploymentTime;

    // Any deposit quote times greater than or less than this value to the current contract time is blocked. Forces
    // caller to use an up to date realized fee. Defaults to 10 minutes.
    uint32 public depositQuoteTimeBuffer = 600;

    // Use count of deposits as unique deposit identifier.
    uint32 public numberOfDeposits;

    // Origin token to destination token routings can be turned on or off.
    mapping(address => mapping(uint256 => bool)) public enabledDepositRoutes;

    struct RootBundle {
        // Merkle root of slow relays that were not fully filled and whose recipient is still owed funds from the LP pool.
        bytes32 slowRelayRoot;
        // Merkle root of relayer refunds.
        bytes32 relayerRefundRoot;
        // This is a 2D bitmap tracking which leafs in the relayer refund root have been claimed, with max size of
        // 256x256 leaves per root.
        mapping(uint256 => uint256) claimedBitmap;
    }
    RootBundle[] public rootBundles;

    // Each relay is associated with the hash of parameters that uniquely identify the original deposit and a relay
    // attempt for that deposit. The relay itself is just represented as the amount filled so far. The total amount to
    // relay, the fees, and the agents are all parameters included in the hash key.
    mapping(bytes32 => uint256) public relayFills;

    /****************************************
     *                EVENTS                *
     ****************************************/
    event SetXDomainAdmin(address indexed newAdmin);
    event SetHubPool(address indexed newHubPool);
    event EnabledDepositRoute(address indexed originToken, uint256 indexed destinationChainId, bool enabled);
    event SetDepositQuoteTimeBuffer(uint32 newBuffer);
    event FundsDeposited(
        uint256 amount,
        uint256 destinationChainId,
        uint64 relayerFeePct,
        uint32 indexed depositId,
        uint32 quoteTimestamp,
        address indexed originToken,
        address recipient,
        address indexed depositor
    );
    event RequestedSpeedUpDeposit(
        uint64 newRelayerFeePct,
        uint32 indexed depositId,
        address indexed depositor,
        bytes depositorSignature
    );
    event FilledRelay(
        bytes32 indexed relayHash,
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 indexed repaymentChainId,
        uint256 originChainId,
        uint64 relayerFeePct,
        uint64 realizedLpFeePct,
        uint32 depositId,
        address destinationToken,
        address indexed relayer,
        address depositor,
        address recipient
    );
    event ExecutedSlowRelayRoot(
        bytes32 indexed relayHash,
        uint256 amount,
        uint256 totalFilledAmount,
        uint256 fillAmount,
        uint256 originChainId,
        uint64 relayerFeePct,
        uint64 realizedLpFeePct,
        uint32 depositId,
        address destinationToken,
        address indexed caller,
        address depositor,
        address recipient
    );
    event RelayedRootBundle(uint32 indexed rootBundleId, bytes32 relayerRefundRoot, bytes32 slowRelayRoot);
    event ExecutedRelayerRefundRoot(
        uint256 amountToReturn,
        uint256 chainId,
        uint256[] refundAmounts,
        uint32 indexed rootBundleId,
        uint32 indexed leafId,
        address l2TokenAddress,
        address[] refundAddresses,
        address indexed caller
    );
    event TokensBridged(
        uint256 amountToReturn,
        uint256 indexed chainId,
        uint32 indexed leafId,
        address indexed l2TokenAddress,
        address caller
    );

    constructor(
        address _crossDomainAdmin,
        address _hubPool,
        address _wethAddress,
        address timerAddress
    ) Testable(timerAddress) {
        _setCrossDomainAdmin(_crossDomainAdmin);
        _setHubPool(_hubPool);
        deploymentTime = uint32(getCurrentTime());
        weth = WETH9(_wethAddress);
    }

    /****************************************
     *               MODIFIERS              *
     ****************************************/

    modifier onlyEnabledRoute(address originToken, uint256 destinationId) {
        require(enabledDepositRoutes[originToken][destinationId], "Disabled route");
        _;
    }

    modifier onlyAdmin() {
        _requireAdminSender();
        _;
    }

    /**************************************
     *          ADMIN FUNCTIONS           *
     **************************************/

    function setCrossDomainAdmin(address newCrossDomainAdmin) public override onlyAdmin nonReentrant {
        _setCrossDomainAdmin(newCrossDomainAdmin);
    }

    function setHubPool(address newHubPool) public override onlyAdmin nonReentrant {
        _setHubPool(newHubPool);
    }

    function setEnableRoute(
        address originToken,
        uint256 destinationChainId,
        bool enabled
    ) public override onlyAdmin nonReentrant {
        enabledDepositRoutes[originToken][destinationChainId] = enabled;
        emit EnabledDepositRoute(originToken, destinationChainId, enabled);
    }

    function setDepositQuoteTimeBuffer(uint32 _depositQuoteTimeBuffer) public override onlyAdmin nonReentrant {
        depositQuoteTimeBuffer = _depositQuoteTimeBuffer;
        emit SetDepositQuoteTimeBuffer(_depositQuoteTimeBuffer);
    }

    // This internal method should be called by an external "relayRootBundle" function that validates the
    // cross domain sender is the HubPool. This validation step differs for each L2, which is why the implementation
    // specifics are left to the implementor of this abstract contract.
    // Once this method is executed and a distribution root is stored in this contract, then `distributeRootBundle`
    // can be called to execute each leaf in the root.
    function relayRootBundle(bytes32 relayerRefundRoot, bytes32 slowRelayRoot) public override onlyAdmin nonReentrant {
        uint32 rootBundleId = uint32(rootBundles.length);
        RootBundle storage rootBundle = rootBundles.push();
        rootBundle.relayerRefundRoot = relayerRefundRoot;
        rootBundle.slowRelayRoot = slowRelayRoot;
        emit RelayedRootBundle(rootBundleId, relayerRefundRoot, slowRelayRoot);
    }

    /**************************************
     *         DEPOSITOR FUNCTIONS        *
     **************************************/

    /**
     * @notice Called by user to bridge funds from origin to destination chain.
     * @dev The caller must first approve this contract to spend `amount` of `originToken`.
     */
    function deposit(
        address recipient,
        address originToken,
        uint256 amount,
        uint256 destinationChainId,
        uint64 relayerFeePct,
        uint32 quoteTimestamp
    ) public payable onlyEnabledRoute(originToken, destinationChainId) nonReentrant {
        // We limit the relay fees to prevent the user spending all their funds on fees.
        require(relayerFeePct < 0.5e18, "invalid relayer fee");
        // Note We assume that L2 timing cannot be compared accurately and consistently to L1 timing. Therefore,
        // `block.timestamp` is different from the L1 EVM's. Therefore, the quoteTimestamp must be within a configurable
        // buffer to allow for this variance.
        // Note also that `quoteTimestamp` cannot be less than the buffer otherwise the following arithmetic can result
        // in underflow. This isn't a problem as the deposit will revert, but the error might be unexpected for clients.
        require(
            getCurrentTime() >= quoteTimestamp - depositQuoteTimeBuffer &&
                getCurrentTime() <= quoteTimestamp + depositQuoteTimeBuffer,
            "invalid quote time"
        );
        // If the address of the origin token is a WETH contract and there is a msg.value with the transaction
        // then the user is sending ETH. In this case, the ETH should be deposited to WETH.
        if (originToken == address(weth) && msg.value > 0) {
            require(msg.value == amount, "msg.value must match amount");
            weth.deposit{ value: msg.value }();
            // Else, it is a normal ERC20. In this case pull the token from the users wallet as per normal.
            // Note: this includes the case where the L2 user has WETH (already wrapped ETH) and wants to bridge them. In
            // this case the msg.value will be set to 0, indicating a "normal" ERC20 bridging action.
        } else IERC20(originToken).safeTransferFrom(msg.sender, address(this), amount);

        emit FundsDeposited(
            amount,
            destinationChainId,
            relayerFeePct,
            numberOfDeposits,
            quoteTimestamp,
            originToken,
            recipient,
            msg.sender
        );

        numberOfDeposits += 1;
    }

    // Convenience method that depositor can use to signal to relayer to use updated fee.
    /**
     * @notice Convenience method that depositor can use to signal to relayer to use updated fee.
     * @dev Relayer should only use events emitted by this function to submit fills with updated fees, otherwise they
     * risk their fills getting disputed for being invalid, for example if the depositor never actually signed the
     * update fee message.
     * @dev This function will revert if the depositor did not sign a message containing the updated fee for the deposit
     * ID stored in this contract. If the deposit ID is for another contract, or the depositor address is incorrect,
     * or the updated fee is incorrect, then the signature will not match and this function will revert.
     * @param depositor Signer of the update fee message who originally submitted the deposit. If the deposit doesn't
     * exist, then the relayer will not be able to fill any relay, so the caller should validate that the depositor
     * did in fact submit a relay.
     * @param newRelayerFeePct New relayer fee that relayers can use.
     * @param depositId Deposit to update fee for that originated in this contract.
     * @param depositorSignature Signed message containing the depositor address, this contract chain ID, the updated
     * relayer fee %, and the deposit ID. This signature is produced by signing a hash of data according to the
     * EIP-191 standard. See more in the `_verifyUpdateRelayerFeeMessage()` comments.
     */
    function speedUpDeposit(
        address depositor,
        uint64 newRelayerFeePct,
        uint32 depositId,
        bytes memory depositorSignature
    ) public nonReentrant {
        _verifyUpdateRelayerFeeMessage(depositor, chainId(), newRelayerFeePct, depositId, depositorSignature);

        // Assuming the above checks passed, a relayer can take the signature and the updated relayer fee information
        // from the following event to submit a fill with an updated fee %.
        emit RequestedSpeedUpDeposit(newRelayerFeePct, depositId, depositor, depositorSignature);
    }

    /**************************************
     *         RELAYER FUNCTIONS          *
     **************************************/

    function fillRelay(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId
    ) public nonReentrant {
        // Each relay attempt is mapped to the hash of data uniquely identifying it, which includes the deposit data
        // such as the origin chain ID and the deposit ID, and the data in a relay attempt such as who the recipient
        // is, which chain and currency the recipient wants to receive funds on, and the relay fees.
        SpokePoolInterface.RelayData memory relayData = SpokePoolInterface.RelayData({
            depositor: depositor,
            recipient: recipient,
            destinationToken: destinationToken,
            amount: amount,
            realizedLpFeePct: realizedLpFeePct,
            relayerFeePct: relayerFeePct,
            depositId: depositId,
            originChainId: originChainId
        });
        bytes32 relayHash = _getRelayHash(relayData);

        uint256 fillAmountPreFees = _fillRelay(relayHash, relayData, maxTokensToSend, relayerFeePct, false);

        _emitFillRelay(relayHash, fillAmountPreFees, repaymentChainId, relayerFeePct, relayData);
    }

    function fillRelayWithUpdatedFee(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 maxTokensToSend,
        uint256 repaymentChainId,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint64 newRelayerFeePct,
        uint32 depositId,
        bytes memory depositorSignature
    ) public nonReentrant {
        _verifyUpdateRelayerFeeMessage(depositor, originChainId, newRelayerFeePct, depositId, depositorSignature);

        // Now follow the default `fillRelay` flow with the updated fee and the original relay hash.
        RelayData memory relayData = RelayData({
            depositor: depositor,
            recipient: recipient,
            destinationToken: destinationToken,
            amount: amount,
            realizedLpFeePct: realizedLpFeePct,
            relayerFeePct: relayerFeePct,
            depositId: depositId,
            originChainId: originChainId
        });
        bytes32 relayHash = _getRelayHash(relayData);
        uint256 fillAmountPreFees = _fillRelay(relayHash, relayData, maxTokensToSend, newRelayerFeePct, false);

        _emitFillRelay(relayHash, fillAmountPreFees, repaymentChainId, newRelayerFeePct, relayData);
    }

    /**************************************
     *         DATA WORKER FUNCTIONS      *
     **************************************/
    function executeSlowRelayRoot(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) public virtual nonReentrant {
        _executeSlowRelayRoot(
            depositor,
            recipient,
            destinationToken,
            amount,
            originChainId,
            realizedLpFeePct,
            relayerFeePct,
            depositId,
            rootBundleId,
            proof
        );
    }

    function executeRelayerRefundRoot(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) public virtual nonReentrant {
        _executeRelayerRefundRoot(rootBundleId, relayerRefundLeaf, proof);
    }

    /**************************************
     *           VIEW FUNCTIONS           *
     **************************************/

    // Some L2s like ZKSync don't support the CHAIN_ID opcode so we allow the caller to manually set this.
    function chainId() public view virtual returns (uint256) {
        return block.chainid;
    }

    /**************************************
     *         INTERNAL FUNCTIONS         *
     **************************************/

    function _executeRelayerRefundRoot(
        uint32 rootBundleId,
        SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf,
        bytes32[] memory proof
    ) internal {
        // Check integrity of leaf structure:
        require(relayerRefundLeaf.chainId == chainId(), "Invalid chainId");
        require(relayerRefundLeaf.refundAddresses.length == relayerRefundLeaf.refundAmounts.length, "invalid leaf");

        RootBundle storage rootBundle = rootBundles[rootBundleId];

        // Check that `inclusionProof` proves that `relayerRefundLeaf` is contained within the relayer refund root.
        // Note: This should revert if the `relayerRefundRoot` is uninitialized.
        require(MerkleLib.verifyRelayerRefund(rootBundle.relayerRefundRoot, relayerRefundLeaf, proof), "Bad Proof");

        // Verify the leafId in the leaf has not yet been claimed.
        require(!MerkleLib.isClaimed(rootBundle.claimedBitmap, relayerRefundLeaf.leafId), "Already claimed");

        // Set leaf as claimed in bitmap. This is passed by reference to the storage rootBundle.
        MerkleLib.setClaimed(rootBundle.claimedBitmap, relayerRefundLeaf.leafId);

        // Wrap any ETH owned by this contract so we can send expected L2 token to recipient. This is neccessary because
        // some SpokePools will receive ETH from the canonical token bridge instead of WETH.
        if (address(this).balance > 0) weth.deposit{ value: address(this).balance }();

        // Send each relayer refund address the associated refundAmount for the L2 token address.
        // Note: Even if the L2 token is not enabled on this spoke pool, we should still refund relayers.
        for (uint32 i = 0; i < relayerRefundLeaf.refundAmounts.length; i++) {
            uint256 amount = relayerRefundLeaf.refundAmounts[i];
            if (amount > 0)
                IERC20(relayerRefundLeaf.l2TokenAddress).safeTransfer(relayerRefundLeaf.refundAddresses[i], amount);
        }

        // If leaf's `amountToReturn` is positive, then send L2 --> L1 message to bridge tokens back via
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

    function _executeSlowRelayRoot(
        address depositor,
        address recipient,
        address destinationToken,
        uint256 amount,
        uint256 originChainId,
        uint64 realizedLpFeePct,
        uint64 relayerFeePct,
        uint32 depositId,
        uint32 rootBundleId,
        bytes32[] memory proof
    ) internal {
        RelayData memory relayData = RelayData({
            depositor: depositor,
            recipient: recipient,
            destinationToken: destinationToken,
            amount: amount,
            originChainId: originChainId,
            realizedLpFeePct: realizedLpFeePct,
            relayerFeePct: relayerFeePct,
            depositId: depositId
        });

        require(
            MerkleLib.verifySlowRelayFulfillment(rootBundles[rootBundleId].slowRelayRoot, relayData, proof),
            "Invalid proof"
        );

        bytes32 relayHash = _getRelayHash(relayData);

        // Note: use relayAmount as the max amount to send, so the relay is always completely filled by the contract's
        // funds in all cases.
        uint256 fillAmountPreFees = _fillRelay(relayHash, relayData, relayData.amount, relayerFeePct, true);

        _emitExecutedSlowRelayRoot(relayHash, fillAmountPreFees, relayData);
    }

    function _setCrossDomainAdmin(address newCrossDomainAdmin) internal {
        require(newCrossDomainAdmin != address(0), "Bad bridge router address");
        crossDomainAdmin = newCrossDomainAdmin;
        emit SetXDomainAdmin(crossDomainAdmin);
    }

    function _setHubPool(address newHubPool) internal {
        require(newHubPool != address(0), "Bad hub pool address");
        hubPool = newHubPool;
        emit SetHubPool(hubPool);
    }

    function _bridgeTokensToHubPool(SpokePoolInterface.RelayerRefundLeaf memory relayerRefundLeaf) internal virtual;

    function _verifyUpdateRelayerFeeMessage(
        address depositor,
        uint256 originChainId,
        uint64 newRelayerFeePct,
        uint32 depositId,
        bytes memory depositorSignature
    ) internal {
        // A depositor can request to speed up an un-relayed deposit by signing a hash containing the relayer
        // fee % to update to and information uniquely identifying the deposit to relay. This information ensures
        // that this signature cannot be re-used for other deposits. The version string is included as a precaution
        // in case this contract is upgraded.
        // Note: we use encode instead of encodePacked because it is more secure, more in the "warning" section
        // here: https://docs.soliditylang.org/en/v0.8.11/abi-spec.html#non-standard-packed-mode
        bytes32 expectedDepositorMessageHash = keccak256(
            abi.encode("ACROSS-V2-FEE-1.0", newRelayerFeePct, depositId, originChainId)
        );

        // Check the hash corresponding to the https://eth.wiki/json-rpc/API#eth_sign[`eth_sign`]
        // JSON-RPC method as part of EIP-191. We use OZ's signature checker library which adds support for
        // EIP-1271 which can verify messages signed by smart contract wallets like Argent and Gnosis safes.
        // If the depositor signed a message with a different updated fee (or any other param included in the
        // above keccak156 hash), then this will revert.
        bytes32 ethSignedMessageHash = ECDSA.toEthSignedMessageHash(expectedDepositorMessageHash);

        _verifyDepositorUpdateFeeMessage(depositor, ethSignedMessageHash, depositorSignature);
    }

    // This function is isolated and made virtual to allow different L2's to implement chain specific recovery of
    // signers from signatures because some L2s might not support `ecrecover`, such as those with account abstraction
    // like ZKSync.
    function _verifyDepositorUpdateFeeMessage(
        address depositor,
        bytes32 ethSignedMessageHash,
        bytes memory depositorSignature
    ) internal view virtual {
        // Note: no need to worry about reentrancy from contract deployed at `depositor` address since
        // `SignatureChecker.isValidSignatureNow` is a non state-modifying STATICCALL:
        // - https://github.com/OpenZeppelin/openzeppelin-contracts/blob/63b466901fb015538913f811c5112a2775042177/contracts/utils/cryptography/SignatureChecker.sol#L35
        // - https://github.com/ethereum/EIPs/pull/214
        require(
            SignatureChecker.isValidSignatureNow(depositor, ethSignedMessageHash, depositorSignature),
            "invalid signature"
        );
    }

    function _computeAmountPreFees(uint256 amount, uint64 feesPct) private pure returns (uint256) {
        return (1e18 * amount) / (1e18 - feesPct);
    }

    function _computeAmountPostFees(uint256 amount, uint64 feesPct) private pure returns (uint256) {
        return (amount * (1e18 - feesPct)) / 1e18;
    }

    // Should we make this public for the relayer's convenience?
    function _getRelayHash(SpokePoolInterface.RelayData memory relayData) private pure returns (bytes32) {
        return keccak256(abi.encode(relayData));
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends WETH.
    function _unwrapWETHTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20(address(weth)).safeTransfer(to, amount);
        } else {
            weth.withdraw(amount);
            to.transfer(amount);
        }
    }

    function _fillRelay(
        bytes32 relayHash,
        RelayData memory relayData,
        uint256 maxTokensToSend,
        uint64 updatableRelayerFeePct,
        bool useContractFunds
    ) internal returns (uint256 fillAmountPreFees) {
        // We limit the relay fees to prevent the user spending all their funds on fees. Note that 0.5e18 (i.e. 50%)
        // fees are just magic numbers. The important point is to prevent the total fee from being 100%, otherwise
        // computing the amount pre fees runs into divide-by-0 issues.
        require(updatableRelayerFeePct < 0.5e18 && relayData.realizedLpFeePct < 0.5e18, "invalid fees");

        // Check that the relay has not already been completely filled. Note that the `relays` mapping will point to
        // the amount filled so far for a particular `relayHash`, so this will start at 0 and increment with each fill.
        require(relayFills[relayHash] < relayData.amount, "relay filled");

        // Stores the equivalent amount to be sent by the relayer before fees have been taken out.
        if (maxTokensToSend == 0) return 0;

        // todo: consider if this code block could be simplified. improve the branching comments and perhaps change the
        // variable names.
        fillAmountPreFees = _computeAmountPreFees(
            maxTokensToSend,
            (relayData.realizedLpFeePct + updatableRelayerFeePct)
        );
        // If user's specified max amount to send is greater than the amount of the relay remaining pre-fees,
        // we'll pull exactly enough tokens to complete the relay.
        uint256 amountToSend = maxTokensToSend;
        if (relayData.amount - relayFills[relayHash] < fillAmountPreFees) {
            fillAmountPreFees = relayData.amount - relayFills[relayHash];
            amountToSend = _computeAmountPostFees(
                fillAmountPreFees,
                relayData.realizedLpFeePct + updatableRelayerFeePct
            );
        }
        relayFills[relayHash] += fillAmountPreFees;
        // If relay token is weth then unwrap and send eth.
        if (relayData.destinationToken == address(weth)) {
            // Note: WETH is already in the contract in the slow relay case.
            if (!useContractFunds)
                IERC20(relayData.destinationToken).safeTransferFrom(msg.sender, address(this), amountToSend);
            _unwrapWETHTo(payable(relayData.recipient), amountToSend);
            // Else, this is a normal ERC20 token. Send to recipient.
        } else {
            // Note: send token directly from the contract to the user in the slow relay case.
            if (!useContractFunds)
                IERC20(relayData.destinationToken).safeTransferFrom(msg.sender, relayData.recipient, amountToSend);
            else IERC20(relayData.destinationToken).safeTransfer(relayData.recipient, amountToSend);
        }
    }

    function _emitFillRelay(
        bytes32 relayHash,
        uint256 fillAmount,
        uint256 repaymentChainId,
        uint64 relayerFeePct,
        RelayData memory relayData
    ) internal {
        emit FilledRelay(
            relayHash,
            relayData.amount,
            relayFills[relayHash],
            fillAmount,
            repaymentChainId,
            relayData.originChainId,
            relayerFeePct,
            relayData.realizedLpFeePct,
            relayData.depositId,
            relayData.destinationToken,
            msg.sender,
            relayData.depositor,
            relayData.recipient
        );
    }

    function _emitExecutedSlowRelayRoot(
        bytes32 relayHash,
        uint256 fillAmount,
        RelayData memory relayData
    ) internal {
        emit ExecutedSlowRelayRoot(
            relayHash,
            relayData.amount,
            relayFills[relayHash],
            fillAmount,
            relayData.originChainId,
            relayData.relayerFeePct,
            relayData.realizedLpFeePct,
            relayData.depositId,
            relayData.destinationToken,
            msg.sender,
            relayData.depositor,
            relayData.recipient
        );
    }

    function _requireAdminSender() internal virtual;

    // Added to enable the this contract to receive ETH. Used when unwrapping Weth.
    receive() external payable {}
}
