// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./HubPoolInterface.sol";
import "./Lockable.sol";

import "./interfaces/AdapterInterface.sol";
import "./interfaces/LpTokenFactoryInterface.sol";
import "./interfaces/WETH9.sol";

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";
import "@uma/core/contracts/common/implementation/AncillaryData.sol";
import "@uma/core/contracts/common/interfaces/AddressWhitelistInterface.sol";
import "@uma/core/contracts/oracle/interfaces/IdentifierWhitelistInterface.sol";

import "@uma/core/contracts/oracle/interfaces/FinderInterface.sol";
import "@uma/core/contracts/oracle/interfaces/StoreInterface.sol";
import "@uma/core/contracts/oracle/interfaces/SkinnyOptimisticOracleInterface.sol";
import "@uma/core/contracts/common/interfaces/ExpandedIERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @notice Contract deployed on Ethereum that houses L1 token liquidity for all SpokePools. A dataworker can interact
 * with merkle roots stored in this contract via inclusion proofs to instruct this contract to send tokens to L2
 * SpokePools via "pool rebalances" that can be used to pay out relayers on those networks. This contract is also
 * responsible for publishing relayer refund and slow relay merkle roots to SpokePools.
 * @notice This contract is meant to act as the cross chain administrator and owner of all L2 spoke pools, so all
 * governance actions and pool rebalances originate from here and bridge instructions to L2s.
 */
contract HubPool is HubPoolInterface, Testable, Lockable, MultiCaller, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    // A data worker can optimistically store several merkle roots on this contract by staking a bond and calling
    // proposeRootBundle. By staking a bond, the data worker is alleging that the merkle roots all
    // contain valid leaves that can be executed later to:
    // - Send funds from this contract to a SpokePool or vice versa
    // - Send funds from a SpokePool to Relayer as a refund for a relayed deposit
    // - Send funds from a SpokePool to a deposit recipient to fulfill a "slow" relay
    // Anyone can dispute this struct if the merkle roots contain invalid leaves before the
    // requestExpirationTimestamp. Once the expiration timestamp is passed, executeRootBundle to execute a leaf
    // from the poolRebalanceRoot on this contract and it will simultaneously publish the relayerRefundRoot and
    // slowRelayRoot to a SpokePool. The latter two roots, once published to the SpokePool, contain
    // leaves that can be executed on the SpokePool to pay relayers or recipients.
    struct RootBundle {
        // Contains leaves instructing this contract to send funds to SpokePools.
        bytes32 poolRebalanceRoot;
        // Relayer refund merkle root to be published to a SpokePool.
        bytes32 relayerRefundRoot;
        // Slow relay merkle root to be published to a SpokePool.
        bytes32 slowRelayRoot;
        // This is a 1D bitmap, with max size of 256 elements, limiting us to 256 chainsIds.
        uint256 claimedBitMap;
        // Proposer of this root bundle.
        address proposer;
        // Whether bond has been repaid to successful root bundle proposer.
        bool proposerBondRepaid;
        // Number of pool rebalance leaves to execute in the poolRebalanceRoot. After this number
        // of leaves are executed, a new root bundle can be proposed
        uint8 unclaimedPoolRebalanceLeafCount;
        // When root bundle challenge period passes and this root bundle becomes executable.
        uint32 requestExpirationTimestamp;
    }

    // Only one root bundle can be stored at a time. Once all pool rebalance leaves are executed, a new proposal
    // can be submitted.
    RootBundle public rootBundleProposal;

    // Whitelist of origin token + ID to destination token routings to be used by off-chain agents. The notion of a
    // route does not need to include L1; it can be L2->L2 route. i.e USDC on Arbitrum -> USDC on Optimism as a "route".
    mapping(bytes32 => address) private whitelistedRoutes;

    struct PooledToken {
        // LP token given to LPs of a specific L1 token.
        address lpToken;
        // True if accepting new LP's.
        bool isEnabled;
        // Timestamp of last LP fee update.
        uint32 lastLpFeeUpdate;
        // Number of LP funds sent via pool rebalances to SpokePools and are expected to be sent
        // back later.
        int256 utilizedReserves;
        // Number of LP funds held in contract less utilized reserves.
        uint256 liquidReserves;
        // Number of LP funds reserved to pay out to LPs as fees.
        uint256 undistributedLpFees;
    }

    // Mapping of L1 token addresses to the associated pool information.
    mapping(address => PooledToken) public pooledTokens;

    // Heler contracts to facilitate cross chain actions between HubPool and SpokePool for a specific network.
    struct CrossChainContract {
        AdapterInterface adapter;
        address spokePool;
    }
    // Mapping of chainId to the associated adapter and spokePool contracts.
    mapping(uint256 => CrossChainContract) public crossChainContracts;

    // WETH contract for Ethereum.
    WETH9 public weth;

    // Helper factory to deploy new LP tokens for enabled L1 tokens
    LpTokenFactoryInterface public lpTokenFactory;

    // Finder contract for this network.
    FinderInterface public finder;

    // When root bundles are disputed a price request is enqueued with the DVM to resolve the resolution.
    bytes32 public identifier = "IS_ACROSS_V2_BUNDLE_VALID";

    // Interest rate payment that scales the amount of pending fees per second paid to LPs. 0.0000015e18 will pay out
    // the full amount of fees entitled to LPs in ~ 7.72 days, just over the standard L2 7 day liveness.
    uint256 public lpFeeRatePerSecond = 1500000000000;

    mapping(address => uint256) public unclaimedAccumulatedProtocolFees;

    // Address that captures protocol fees. Accumulated protocol fees can be claimed by this address.
    address public protocolFeeCaptureAddress;

    // Percentage of lpFees that are captured by the protocol and claimable by the protocolFeeCaptureAddress.
    uint256 public protocolFeeCapturePct;

    // Token used to bond the data worker for proposing relayer refund bundles.
    IERC20 public bondToken;

    // The computed bond amount as the UMA Store's final fee multiplied by the bondTokenFinalFeeMultiplier.
    uint256 public bondAmount;

    // Each root bundle proposal must stay in liveness for this period of time before it can be considered finalized.
    // It can be disputed only during this period of time. Defaults to 2 hours, like the rest of the UMA ecosystem.
    uint32 public liveness = 7200;

    event ProtocolFeeCaptureSet(address indexed newProtocolFeeCaptureAddress, uint256 indexed newProtocolFeeCapturePct);

    event ProtocolFeesCapturedClaimed(address indexed l1Token, uint256 indexed accumulatedFees);

    event BondSet(address indexed newBondToken, uint256 newBondAmount);

    event LivenessSet(uint256 newLiveness);

    event IdentifierSet(bytes32 newIdentifier);

    event CrossChainContractsSet(uint256 l2ChainId, address adapter, address spokePool);

    event L1TokenEnabledForLiquidityProvision(address l1Token, address lpToken);

    event L2TokenDisabledForLiquidityProvision(address l1Token, address lpToken);

    event LiquidityAdded(
        address indexed l1Token,
        uint256 amount,
        uint256 lpTokensMinted,
        address indexed liquidityProvider
    );
    event LiquidityRemoved(
        address indexed l1Token,
        uint256 amount,
        uint256 lpTokensBurnt,
        address indexed liquidityProvider
    );
    event WhitelistRoute(
        uint256 indexed originChainId,
        uint256 indexed destinationChainId,
        address indexed originToken,
        address destinationToken,
        bool enableRoute
    );

    event ProposeRootBundle(
        uint32 requestExpirationTimestamp,
        uint64 unclaimedPoolRebalanceLeafCount,
        uint256[] bundleEvaluationBlockNumbers,
        bytes32 indexed poolRebalanceRoot,
        bytes32 indexed relayerRefundRoot,
        bytes32 slowRelayRoot,
        address indexed proposer
    );
    event RootBundleExecuted(
        uint256 indexed leafId,
        uint256 indexed chainId,
        address[] l1Token,
        uint256[] bundleLpFees,
        int256[] netSendAmount,
        int256[] runningBalance,
        address indexed caller
    );
    event SpokePoolAdminFunctionTriggered(uint256 indexed chainId, bytes message);

    event RootBundleDisputed(address indexed disputer, uint256 requestTime, bytes disputedAncillaryData);

    event RootBundleCanceled(address indexed disputer, uint256 requestTime, bytes disputedAncillaryData);

    modifier noActiveRequests() {
        require(!_activeRequest(), "proposal has unclaimed leafs");
        _;
    }

    modifier zeroOptimisticOracleApproval() {
        _;
        bondToken.safeApprove(address(_getOptimisticOracle()), 0);
    }

    /**
     * @notice Construct HubPool.
     * @param _lpTokenFactory LP Token factory address used to deploy LP tokens for new collateral types.
     * @param _finder Finder address.
     * @param _weth WETH address.
     * @param _timer Timer address.
     */
    constructor(
        LpTokenFactoryInterface _lpTokenFactory,
        FinderInterface _finder,
        WETH9 _weth,
        address _timer
    ) Testable(_timer) {
        lpTokenFactory = _lpTokenFactory;
        finder = _finder;
        weth = _weth;
        protocolFeeCaptureAddress = owner();
    }

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

    /**
     * @notice Sends message to SpokePool from this contract. Callable only by owner.
     * @dev This function has permission to call onlyAdmin functions on the SpokePool, so its imperative
     * that this contract only allows the owner to call this method directly or indirectly.
     * @param chainId Chain with SpokePool to send message to.
     * @param functionData ABI encoded function call to send to SpokePool, but can be any arbitrary data technically.
     */
    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData)
        public
        override
        onlyOwner
        nonReentrant
    {
        _relaySpokePoolAdminFunction(chainId, functionData);
    }

    /**
     * @notice Sets protocolFeeCaptureAddress and protocolFeeCapturePct. Callable only by owner.
     * @param newProtocolFeeCaptureAddress New protocol fee capture address.
     * @param newProtocolFeeCapturePct New protocol fee capture %.
     */
    function setProtocolFeeCapture(address newProtocolFeeCaptureAddress, uint256 newProtocolFeeCapturePct)
        public
        override
        onlyOwner
    {
        require(newProtocolFeeCapturePct <= 1e18, "Bad protocolFeeCapturePct");
        protocolFeeCaptureAddress = newProtocolFeeCaptureAddress;
        protocolFeeCapturePct = newProtocolFeeCapturePct;
        emit ProtocolFeeCaptureSet(newProtocolFeeCaptureAddress, newProtocolFeeCapturePct);
    }

    /**
     * @notice Sets bond token and amount. Callable only by owner.
     * @param newBondToken New bond currency.
     * @param newBondAmount New bond amount.
     */
    function setBond(IERC20 newBondToken, uint256 newBondAmount)
        public
        override
        onlyOwner
        noActiveRequests
        nonReentrant
    {
        // Check that this token is on the whitelist.
        AddressWhitelistInterface addressWhitelist = AddressWhitelistInterface(
            finder.getImplementationAddress(OracleInterfaces.CollateralWhitelist)
        );
        require(addressWhitelist.isOnWhitelist(address(newBondToken)), "Not on whitelist");

        // The bond should be the passed in bondAmount + the final fee.
        bondToken = newBondToken;
        bondAmount = newBondAmount + _getBondTokenFinalFee();
        emit BondSet(address(newBondToken), bondAmount);
    }

    /**
     * @notice Sets root bundle proposal liveness period. Callable only by owner.
     * @param newLiveness New liveness period.
     */
    function setLiveness(uint32 newLiveness) public override onlyOwner {
        require(newLiveness > 10 minutes, "Liveness too short");
        liveness = newLiveness;
        emit LivenessSet(newLiveness);
    }

    /**
     * @notice Sets identifier for root bundle disputes.. Callable only by owner.
     * @param newIdentifier New identifier.
     */
    function setIdentifier(bytes32 newIdentifier) public override onlyOwner noActiveRequests nonReentrant {
        IdentifierWhitelistInterface identifierWhitelist = IdentifierWhitelistInterface(
            finder.getImplementationAddress(OracleInterfaces.IdentifierWhitelist)
        );
        require(identifierWhitelist.isIdentifierSupported(newIdentifier), "Identifier not supported");
        identifier = newIdentifier;
        emit IdentifierSet(newIdentifier);
    }

    /**
     * @notice Sets cross chain relay helper contracts for L2 chain ID. Callable only by owner.
     * @param l2ChainId Chain to set contracts for.
     * @param adapter Adapter used to relay messages and tokens to spoke pool.
     * @param spokePool Recipient of relayed messages and tokens on SpokePool.
     */

    function setCrossChainContracts(
        uint256 l2ChainId,
        address adapter,
        address spokePool
    ) public override onlyOwner {
        crossChainContracts[l2ChainId] = CrossChainContract(AdapterInterface(adapter), spokePool);
        emit CrossChainContractsSet(l2ChainId, adapter, spokePool);
    }

    /**
     * @notice Whitelist an origin chain ID + token <-> destination token route. Callable only by owner.
     * @param originChainId Chain where deposit occurs.
     * @param destinationChainId Chain where depositor wants to receive funds.
     * @param originToken Deposited token.
     * @param destinationToken Token that depositor wants to receive on destination chain. Unused if `enableRoute` is
     * False.
     * @param enableRoute Set to true to enable route on L2 and whitelist new destination token, or False to disable
     * route on L2 and delete destination token mapping on this contract.
     */
    function whitelistRoute(
        uint256 originChainId,
        uint256 destinationChainId,
        address originToken,
        address destinationToken,
        bool enableRoute
    ) public override onlyOwner nonReentrant {
        if (enableRoute)
            whitelistedRoutes[_whitelistedRouteKey(originChainId, originToken, destinationChainId)] = destinationToken;
        else delete whitelistedRoutes[_whitelistedRouteKey(originChainId, originToken, destinationChainId)];

        // Whitelist the same route on the origin network.
        _relaySpokePoolAdminFunction(
            originChainId,
            abi.encodeWithSignature(
                "setEnableRoute(address,uint256,bool)",
                originToken,
                destinationChainId,
                enableRoute
            )
        );

        // @dev Client should ignore `destinationToken` value if `enableRoute == False`.
        emit WhitelistRoute(originChainId, destinationChainId, originToken, destinationToken, enableRoute);
    }

    /**
     * @notice Enables LPs to provide liquidity for L1 token. Deploys new LP token for L1 token if appropriate.
     * Callable only by owner.
     * @param l1Token Token to provide liquidity for.
     */
    function enableL1TokenForLiquidityProvision(address l1Token) public override onlyOwner nonReentrant {
        if (pooledTokens[l1Token].lpToken == address(0))
            pooledTokens[l1Token].lpToken = lpTokenFactory.createLpToken(l1Token);

        pooledTokens[l1Token].isEnabled = true;
        pooledTokens[l1Token].lastLpFeeUpdate = uint32(getCurrentTime());

        emit L1TokenEnabledForLiquidityProvision(l1Token, pooledTokens[l1Token].lpToken);
    }

    /**
     * @notice Disables LPs from providing liquidity for L1 token. Callable only by owner.
     * @param l1Token Token to disable liquidity provision for.
     */
    function disableL1TokenForLiquidityProvision(address l1Token) public override onlyOwner {
        pooledTokens[l1Token].isEnabled = false;
        emit L2TokenDisabledForLiquidityProvision(l1Token, pooledTokens[l1Token].lpToken);
    }

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    /**
     * @notice Deposit liquidity into this contract to earn LP fees in exchange for funding relays on SpokePools.
     * Caller is essentially loaning their funds to be sent from this contract to the SpokePool, where it will be used
     * to repay a relayer, and ultimately receives their loan back after the tokens are bridged back to this contract
     * via the canonical token bridge. Then, the caller's loans are used for again. This loan cycle repeats continuously
     * and the caller, or "liquidity provider" earns a continuous fee for their credit that they are extending relayers.
     * @notice Caller will receive an LP token representing their share of this pool. The LP token's redemption value
     * increments from the time that they enter the pool to reflect their accrued fees.
     * @param l1Token Token to deposit into this contract.
     * @param l1TokenAmount Amount of liquidity to provide.
     */
    function addLiquidity(address l1Token, uint256 l1TokenAmount) public payable override nonReentrant {
        require(pooledTokens[l1Token].isEnabled, "Token not enabled");
        // If this is the weth pool and the caller sends msg.value then the msg.value must match the l1TokenAmount.
        // Else, msg.value must be set to 0.
        require(((address(weth) == l1Token) && msg.value == l1TokenAmount) || msg.value == 0, "Bad msg.value");

        // Since _exchangeRateCurrent() reads this contract's balance and updates contract state using it, it must be
        // first before transferring any tokens to this contract to ensure synchronization.
        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / _exchangeRateCurrent(l1Token);
        ExpandedIERC20(pooledTokens[l1Token].lpToken).mint(msg.sender, lpTokensToMint);
        pooledTokens[l1Token].liquidReserves += l1TokenAmount;

        if (address(weth) == l1Token && msg.value > 0) WETH9(address(l1Token)).deposit{ value: msg.value }();
        else IERC20(l1Token).safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        emit LiquidityAdded(l1Token, l1TokenAmount, lpTokensToMint, msg.sender);
    }

    /**
     * @notice Burns LP share to redeem for underlying l1Token original deposit amount plus fees.
     * @param l1Token Token to redeem LP share for.
     * @param lpTokenAmount Amount of LP tokens to burn. Exchange rate between L1 token and LP token can be queried
     * via public exchangeRateCurrent method.
     * @param sendEth Set to True if L1 token is WETH and user wants to receive ETH.
     */
    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) public override nonReentrant {
        require(address(weth) == l1Token || !sendEth, "Cant send eth");
        uint256 l1TokensToReturn = (lpTokenAmount * _exchangeRateCurrent(l1Token)) / 1e18;

        ExpandedIERC20(pooledTokens[l1Token].lpToken).burnFrom(msg.sender, lpTokenAmount);
        // Note this method does not make any liquidity utilization checks before letting the LP redeem their LP tokens.
        // If they try access more funds that available (i.e l1TokensToReturn > liquidReserves) this will underflow.
        pooledTokens[l1Token].liquidReserves -= l1TokensToReturn;

        if (sendEth) _unwrapWETHTo(payable(msg.sender), l1TokensToReturn);
        else IERC20(l1Token).safeTransfer(msg.sender, l1TokensToReturn);

        emit LiquidityRemoved(l1Token, l1TokensToReturn, lpTokenAmount, msg.sender);
    }

    /**
     * @notice Returns exchange rate of L1 token to LP token.
     * @param l1Token L1 token redeemable by burning LP token.
     * @return Amount of L1 tokens redeemable for 1 unit LP token.
     */
    function exchangeRateCurrent(address l1Token) public override nonReentrant returns (uint256) {
        return _exchangeRateCurrent(l1Token);
    }

    /**
     * @notice Returns % of liquid reserves currently being "used" and sitting in SpokePools.
     * @param l1Token L1 token to query utilization for.
     * @return % of liquid reserves currently being "used" and sitting in SpokePools.
     */
    function liquidityUtilizationCurrent(address l1Token) public override nonReentrant returns (uint256) {
        return _liquidityUtilizationPostRelay(l1Token, 0);
    }

    /**
     * @notice Returns % of liquid reserves currently being "used" and sitting in SpokePools and accounting for
     * relayedAmount of tokens to be withdrawn from the pool.
     * @param l1Token L1 token to query utilization for.
     * @param relayedAmount The higher this amount, the higher the utilization.
     * @return % of liquid reserves currently being "used" and sitting in SpokePools plus the relayedAmount.
     */
    function liquidityUtilizationPostRelay(address l1Token, uint256 relayedAmount)
        public
        nonReentrant
        returns (uint256)
    {
        return _liquidityUtilizationPostRelay(l1Token, relayedAmount);
    }

    /**
     * @notice Synchronize any balance changes in this contract with the utilized & liquid reserves. This should be done
     * at the conclusion of a L2->L1 token transfer via the canonical token bridge, when this contract's reserves do not
     * reflect its true balance due to new tokens being dropped onto the contract at the conclusion of a bridging action.
     */
    function sync(address l1Token) public override nonReentrant {
        _sync(l1Token);
    }

    /*************************************************
     *             DATA WORKER FUNCTIONS             *
     *************************************************/

    /**
     * @notice Publish a new root bundle to along with all of the block numbers that the merkle roots are relevant for.
     * This is used to aid off-chain validators in evaluating the correctness of this bundle. Caller stakes a bond that
     * can be slashed if the root bundle proposal is invalid, and they will receive it back if accepted.
     * @notice After proposeRootBundle is called, if the any props are wrong then this proposal can be challenged.
     * Once the challenge period passes, then the roots are no longer disputable, and only executeRootBundle can be
     * called; moreover, this method can't be called again until all leafs are executed.
     * @param bundleEvaluationBlockNumbers should contain the latest block number for all chains, even if there are no
     * relays contained on some of them. The usage of this variable should be defined in an off chain UMIP.
     * @param poolRebalanceLeafCount Number of leaves contained in pool rebalance root. Max is the number of whitelisted chains.
     * @param poolRebalanceRoot Pool rebalance root containing leaves that will send tokens from this contract to a SpokePool.
     * @param relayerRefundRoot Relayer refund root to publish to SpokePool where a data worker can execute leaves to
     * refund relayers on their chosen refund chainId.
     * @param slowRelayRoot Slow relay root to publish to Spoke Pool where a data worker can execute leaves to
     * fulfill slow relays.
     */
    function proposeRootBundle(
        uint256[] memory bundleEvaluationBlockNumbers,
        uint8 poolRebalanceLeafCount,
        bytes32 poolRebalanceRoot,
        bytes32 relayerRefundRoot,
        bytes32 slowRelayRoot
    ) public override nonReentrant noActiveRequests {
        // Note: this is to prevent "empty block" style attacks where someone can make empty proposals that are
        // technically valid but not useful. This could also potentially be enforced at the UMIP-level.
        require(poolRebalanceLeafCount > 0, "Bundle must have at least 1 leaf");

        uint32 requestExpirationTimestamp = uint32(getCurrentTime()) + liveness;

        delete rootBundleProposal; // Only one bundle of roots can be executed at a time.

        rootBundleProposal.requestExpirationTimestamp = requestExpirationTimestamp;
        rootBundleProposal.unclaimedPoolRebalanceLeafCount = poolRebalanceLeafCount;
        rootBundleProposal.poolRebalanceRoot = poolRebalanceRoot;
        rootBundleProposal.relayerRefundRoot = relayerRefundRoot;
        rootBundleProposal.slowRelayRoot = slowRelayRoot;
        rootBundleProposal.proposer = msg.sender;

        // Pull bondAmount of bondToken from the caller.
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        emit ProposeRootBundle(
            requestExpirationTimestamp,
            poolRebalanceLeafCount,
            bundleEvaluationBlockNumbers,
            poolRebalanceRoot,
            relayerRefundRoot,
            slowRelayRoot,
            msg.sender
        );
    }

    function executeRootBundle(
        uint256 chainId,
        uint256[] memory bundleLpFees,
        int256[] memory netSendAmounts,
        int256[] memory runningBalances,
        uint8 leafId,
        address[] memory l1Tokens,
        bytes32[] memory proof
    ) public nonReentrant {
        require(getCurrentTime() > rootBundleProposal.requestExpirationTimestamp, "Not passed liveness");

        // Verify the leafId in the poolRebalanceLeaf has not yet been claimed.
        require(!MerkleLib.isClaimed1D(rootBundleProposal.claimedBitMap, leafId), "Already claimed");

        // Verify the props provided generate a leaf that, along with the proof, are included in the merkle root.
        require(
            MerkleLib.verifyPoolRebalance(
                rootBundleProposal.poolRebalanceRoot,
                PoolRebalanceLeaf({
                    chainId: chainId,
                    bundleLpFees: bundleLpFees,
                    netSendAmounts: netSendAmounts,
                    runningBalances: runningBalances,
                    leafId: leafId,
                    l1Tokens: l1Tokens
                }),
                proof
            ),
            "Bad Proof"
        );

        // Before interacting with a particular chain's adapter, ensure that the adapter is set.
        require(address(crossChainContracts[chainId].adapter) != address(0), "No adapter for chain");

        // Make sure SpokePool address is initialized since _sendTokensToChainAndUpdatePooledTokenTrackers() will not
        // revert if its accidentally set to address(0). We don't make the same check on the adapter for this
        // chainId because the internal method's delegatecall() to the adapter will revert if its address is set
        // incorrectly.
        address spokePool = crossChainContracts[chainId].spokePool;
        require(spokePool != address(0), "Uninitialized spoke pool");

        // Set the leafId in the claimed bitmap.
        rootBundleProposal.claimedBitMap = MerkleLib.setClaimed1D(rootBundleProposal.claimedBitMap, leafId);

        // Decrement the unclaimedPoolRebalanceLeafCount.
        rootBundleProposal.unclaimedPoolRebalanceLeafCount--;

        _sendTokensToChainAndUpdatePooledTokenTrackers(spokePool, chainId, l1Tokens, netSendAmounts, bundleLpFees);
        _relayRootBundleToSpokePool(spokePool, chainId);

        // Transfer the bondAmount to back to the proposer, if this the last executed leaf. Only sending this once all
        // leafs have been executed acts to force the data worker to execute all bundles or they wont receive their bond.
        if (rootBundleProposal.unclaimedPoolRebalanceLeafCount == 0)
            bondToken.safeTransfer(rootBundleProposal.proposer, bondAmount);

        emit RootBundleExecuted(leafId, chainId, l1Tokens, bundleLpFees, netSendAmounts, runningBalances, msg.sender);
    }

    /**
     * @notice Caller stakes a bond to dispute the current root bundle proposal assuming it has not passed liveness
     * yet. The proposal is deleted, allowing a follow-up proposal to be submitted, and the dispute is sent to the
     * optimistic oracle to be adjudicated. Can only be called within the liveness period of the current proposal.
     */
    function disputeRootBundle() public nonReentrant zeroOptimisticOracleApproval {
        uint32 currentTime = uint32(getCurrentTime());
        require(currentTime <= rootBundleProposal.requestExpirationTimestamp, "Request passed liveness");

        // Request price from OO and dispute it.
        bytes memory requestAncillaryData = getRootBundleProposalAncillaryData();
        uint256 finalFee = _getBondTokenFinalFee();

        // If the finalFee is larger than the bond amount, the bond amount needs to be reset before a request can go
        // through. Cancel to avoid a revert.
        if (finalFee > bondAmount) {
            _cancelBundle(requestAncillaryData);
            return;
        }

        SkinnyOptimisticOracleInterface optimisticOracle = _getOptimisticOracle();

        // Only approve exact tokens to avoid more tokens than expected being pulled into the OptimisticOracle.
        bondToken.safeIncreaseAllowance(address(optimisticOracle), bondAmount);
        try
            optimisticOracle.requestAndProposePriceFor(
                identifier,
                currentTime,
                requestAncillaryData,
                bondToken,
                // Set reward to 0, since we'll settle proposer reward payouts directly from this contract after a root
                // proposal has passed the challenge period.
                0,
                // Set the Optimistic oracle proposer bond for the price request.
                bondAmount - finalFee,
                // Set the Optimistic oracle liveness for the price request.
                liveness,
                rootBundleProposal.proposer,
                // Canonical value representing "True"; i.e. the proposed relay is valid.
                int256(1e18)
            )
        returns (uint256) {
            // Ensure that approval == 0 after the call so the increaseAllowance call below doesn't allow more tokens
            // to transfer than intended.
            bondToken.safeApprove(address(optimisticOracle), 0);
        } catch {
            // Cancel the bundle since the proposal failed.
            _cancelBundle(requestAncillaryData);
            return;
        }

        // Dispute the request that we just sent.
        SkinnyOptimisticOracleInterface.Request memory ooPriceRequest = SkinnyOptimisticOracleInterface.Request({
            proposer: rootBundleProposal.proposer,
            disputer: address(0),
            currency: bondToken,
            settled: false,
            proposedPrice: int256(1e18),
            resolvedPrice: 0,
            expirationTime: currentTime + liveness,
            reward: 0,
            finalFee: finalFee,
            bond: bondAmount - finalFee,
            customLiveness: liveness
        });

        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);
        bondToken.safeIncreaseAllowance(address(optimisticOracle), bondAmount);
        optimisticOracle.disputePriceFor(
            identifier,
            currentTime,
            requestAncillaryData,
            ooPriceRequest,
            msg.sender,
            address(this)
        );

        emit RootBundleDisputed(msg.sender, currentTime, requestAncillaryData);

        // Finally, delete the state pertaining to the active proposal so that another proposer can submit a new bundle.
        delete rootBundleProposal;
    }

    /**
     * @notice Send unclaimed accumulated protocol fees to fee capture address.
     * @param l1Token Token whose protocol fees the caller wants to disburse.
     */
    function claimProtocolFeesCaptured(address l1Token) public override nonReentrant {
        IERC20(l1Token).safeTransfer(protocolFeeCaptureAddress, unclaimedAccumulatedProtocolFees[l1Token]);
        emit ProtocolFeesCapturedClaimed(l1Token, unclaimedAccumulatedProtocolFees[l1Token]);
        unclaimedAccumulatedProtocolFees[l1Token] = 0;
    }

    /**
     * @notice Returns ancillary data containing all relevant root bundle data that voters can format into UTF8 and
     * use to determine if the root bundle proposal is valid.
     * @return ancillaryData Ancillary data that can be decoded into UTF8.
     */
    function getRootBundleProposalAncillaryData() public view override returns (bytes memory ancillaryData) {
        ancillaryData = AncillaryData.appendKeyValueUint(
            "",
            "requestExpirationTimestamp",
            rootBundleProposal.requestExpirationTimestamp
        );

        ancillaryData = AncillaryData.appendKeyValueUint(
            ancillaryData,
            "unclaimedPoolRebalanceLeafCount",
            rootBundleProposal.unclaimedPoolRebalanceLeafCount
        );
        ancillaryData = AncillaryData.appendKeyValueBytes32(
            ancillaryData,
            "poolRebalanceRoot",
            rootBundleProposal.poolRebalanceRoot
        );
        ancillaryData = AncillaryData.appendKeyValueBytes32(
            ancillaryData,
            "relayerRefundRoot",
            rootBundleProposal.relayerRefundRoot
        );
        ancillaryData = AncillaryData.appendKeyValueBytes32(
            ancillaryData,
            "slowRelayRoot",
            rootBundleProposal.slowRelayRoot
        );
        ancillaryData = AncillaryData.appendKeyValueUint(
            ancillaryData,
            "claimedBitMap",
            rootBundleProposal.claimedBitMap
        );
        ancillaryData = AncillaryData.appendKeyValueAddress(ancillaryData, "proposer", rootBundleProposal.proposer);
    }

    /**
     * @notice Conveniently queries whether an origin chain + token => destination chain ID is whitelisted and returns
     * the whitelisted destination token.
     * @param originChainId Deposit chain.
     * @param originToken Deposited token.
     * @param destinationChainId Where depositor can receive funds.
     * @return address Depositor can receive this token on destination chain ID.
     */
    function whitelistedRoute(
        uint256 originChainId,
        address originToken,
        uint256 destinationChainId
    ) public view override returns (address) {
        return whitelistedRoutes[_whitelistedRouteKey(originChainId, originToken, destinationChainId)];
    }

    /**
     * @notice This function allows a caller to load the contract with raw ETH to perform L2 calls. This is needed for arbitrum
     * calls, but may also be needed for others.
     */
    function loadEthForL2Calls() public payable override {}

    /*************************************************
     *              INTERNAL FUNCTIONS               *
     *************************************************/

    // Called when a dispute fails due to parameter changes. This effectively resets the state and cancels the request
    // with no loss of funds, thereby enabling a new bundle to be added.
    function _cancelBundle(bytes memory ancillaryData) internal {
        bondToken.transfer(rootBundleProposal.proposer, bondAmount);
        delete rootBundleProposal;
        emit RootBundleCanceled(msg.sender, getCurrentTime(), ancillaryData);
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

    function _getOptimisticOracle() internal view returns (SkinnyOptimisticOracleInterface) {
        return
            SkinnyOptimisticOracleInterface(finder.getImplementationAddress(OracleInterfaces.SkinnyOptimisticOracle));
    }

    function _getBondTokenFinalFee() internal view returns (uint256) {
        return
            StoreInterface(finder.getImplementationAddress(OracleInterfaces.Store))
                .computeFinalFee(address(bondToken))
                .rawValue;
    }

    // Note this method does a lot and wraps together the sending of tokens and updating the pooled token trackers. This
    // is done as a gas saving so we don't need to iterate over the l1Tokens multiple times.
    function _sendTokensToChainAndUpdatePooledTokenTrackers(
        address spokePool,
        uint256 chainId,
        address[] memory l1Tokens,
        int256[] memory netSendAmounts,
        uint256[] memory bundleLpFees
    ) internal {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;

        for (uint32 i = 0; i < l1Tokens.length; i++) {
            address l1Token = l1Tokens[i];
            // Validate the L1 -> L2 token route is whitelisted. If it is not then the output of the bridging action
            // could send tokens to the 0x0 address on the L2.
            address l2Token = whitelistedRoutes[_whitelistedRouteKey(block.chainid, l1Token, chainId)];
            require(l2Token != address(0), "Route not whitelisted");

            // If the net send amount for this token is positive then: 1) send tokens from L1->L2 to facilitate the L2
            // relayer refund, 2) Update the liquidity trackers for the associated pooled tokens.
            if (netSendAmounts[i] > 0) {
                // Perform delegatecall to use the adapter's code with this contract's context. Opt for delegatecall's
                // complexity in exchange for lower gas costs.
                (bool success, ) = address(adapter).delegatecall(
                    abi.encodeWithSignature(
                        "relayTokens(address,address,uint256,address)",
                        l1Token, // l1Token.
                        l2Token, // l2Token.
                        uint256(netSendAmounts[i]), // amount.
                        spokePool // to. This should be the spokePool.
                    )
                );
                require(success, "delegatecall failed");

                // Liquid reserves is decreased by the amount sent. utilizedReserves is increased by the amount sent.
                pooledTokens[l1Token].utilizedReserves += netSendAmounts[i];
                pooledTokens[l1Token].liquidReserves -= uint256(netSendAmounts[i]);
            }

            // Allocate LP fees and protocol fees from the bundle to the associated pooled token trackers.
            _allocateLpAndProtocolFees(l1Token, bundleLpFees[i]);
        }
    }

    function _relayRootBundleToSpokePool(address spokePool, uint256 chainId) internal {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;

        // Perform delegatecall to use the adapter's code with this contract's context.
        (bool success, ) = address(adapter).delegatecall(
            abi.encodeWithSignature(
                "relayMessage(address,bytes)",
                spokePool, // target. This should be the spokePool on the L2.
                abi.encodeWithSignature(
                    "relayRootBundle(bytes32,bytes32)",
                    rootBundleProposal.relayerRefundRoot,
                    rootBundleProposal.slowRelayRoot
                ) // message
            )
        );
        require(success, "delegatecall failed");
    }

    function _exchangeRateCurrent(address l1Token) internal returns (uint256) {
        PooledToken storage pooledToken = pooledTokens[l1Token]; // Note this is storage so the state can be modified.
        uint256 lpTokenTotalSupply = IERC20(pooledToken.lpToken).totalSupply();
        if (lpTokenTotalSupply == 0) return 1e18; // initial rate is 1:1 between LP tokens and collateral.

        // First, update fee counters and local accounting of finalized transfers from L2 -> L1.
        _updateAccumulatedLpFees(pooledToken); // Accumulate all allocated fees from the last time this method was called.
        _sync(l1Token); // Fetch any balance changes due to token bridging finalization and factor them in.

        // ExchangeRate := (liquidReserves + utilizedReserves - undistributedLpFees) / lpTokenSupply
        // Both utilizedReserves and undistributedLpFees contain assigned LP fees. UndistributedLpFees is gradually
        // decreased over the smear duration using _updateAccumulatedLpFees. This means that the exchange rate will
        // gradually increase over time as undistributedLpFees goes to zero.
        // utilizedReserves can be negative. If this is the case, then liquidReserves is offset by an equal
        // and opposite size. LiquidReserves + utilizedReserves will always be larger than undistributedLpFees so this
        // int will always be positive so there is no risk in underflow in type casting in the return line.
        int256 numerator = int256(pooledToken.liquidReserves) +
            pooledToken.utilizedReserves -
            int256(pooledToken.undistributedLpFees);
        return (uint256(numerator) * 1e18) / lpTokenTotalSupply;
    }

    // Update internal fee counters by adding in any accumulated fees from the last time this logic was called.
    function _updateAccumulatedLpFees(PooledToken storage pooledToken) internal {
        uint256 accumulatedFees = _getAccumulatedFees(pooledToken.undistributedLpFees, pooledToken.lastLpFeeUpdate);
        pooledToken.undistributedLpFees -= accumulatedFees;
        pooledToken.lastLpFeeUpdate = uint32(getCurrentTime());
    }

    // Calculate the unallocated accumulatedFees from the last time the contract was called.
    function _getAccumulatedFees(uint256 undistributedLpFees, uint256 lastLpFeeUpdate) internal view returns (uint256) {
        // accumulatedFees := min(undistributedLpFees * lpFeeRatePerSecond * timeFromLastInteraction, undistributedLpFees)
        // The min acts to pay out all fees in the case the equation returns more than the remaining a fees.
        uint256 timeFromLastInteraction = getCurrentTime() - lastLpFeeUpdate;
        uint256 maxUndistributedLpFees = (undistributedLpFees * lpFeeRatePerSecond * timeFromLastInteraction) / (1e18);
        return maxUndistributedLpFees < undistributedLpFees ? maxUndistributedLpFees : undistributedLpFees;
    }

    function _sync(address l1Token) internal {
        // Check if the l1Token balance of the contract is greater than the liquidReserves. If it is then the bridging
        // action from L2 -> L1 has concluded and the local accounting can be updated.
        // Note: this calculation must take into account the bond when it's acting on the bond token and there's an
        // active request.
        uint256 balance = IERC20(l1Token).balanceOf(address(this));
        uint256 balanceSansBond = l1Token == address(bondToken) && _activeRequest() ? balance - bondAmount : balance;
        if (balanceSansBond > pooledTokens[l1Token].liquidReserves) {
            // Note the numerical operation below can send utilizedReserves to negative. This can occur when tokens are
            // dropped onto the contract, exceeding the liquidReserves.
            pooledTokens[l1Token].utilizedReserves -= int256(balanceSansBond - pooledTokens[l1Token].liquidReserves);
            pooledTokens[l1Token].liquidReserves = balanceSansBond;
        }
    }

    function _liquidityUtilizationPostRelay(address l1Token, uint256 relayedAmount) internal returns (uint256) {
        _sync(l1Token); // Fetch any balance changes due to token bridging finalization and factor them in.

        // liquidityUtilizationRatio := (relayedAmount + max(utilizedReserves,0)) / (liquidReserves + max(utilizedReserves,0))
        // UtilizedReserves has a dual meaning: if it's greater than zero then it represents funds pending in the bridge
        // that will flow from L2 to L1. In this case, we can use it normally in the equation. However, if it is
        // negative, then it is already counted in liquidReserves. This occurs if tokens are transferred directly to the
        // contract. In this case, ignore it as it is captured in liquid reserves and has no meaning in the numerator.
        PooledToken memory pooledToken = pooledTokens[l1Token]; // Note this is storage so the state can be modified.
        uint256 flooredUtilizedReserves = pooledToken.utilizedReserves > 0 ? uint256(pooledToken.utilizedReserves) : 0;
        uint256 numerator = relayedAmount + flooredUtilizedReserves;
        uint256 denominator = pooledToken.liquidReserves + flooredUtilizedReserves;

        // If the denominator equals zero, return 1e18 (max utilization).
        if (denominator == 0) return 1e18;

        // In all other cases, return the utilization ratio.
        return (numerator * 1e18) / denominator;
    }

    function _allocateLpAndProtocolFees(address l1Token, uint256 bundleLpFees) internal {
        // Calculate the fraction of bundledLpFees that are allocated to the protocol and to the LPs.
        uint256 protocolFeesCaptured = (bundleLpFees * protocolFeeCapturePct) / 1e18;
        uint256 lpFeesCaptured = bundleLpFees - protocolFeesCaptured;

        // Assign any LP fees included into the bundle to the pooled token. These LP fees are tracked in the
        // undistributedLpFees and within the utilizedReserves. undistributedLpFees is gradually decrease
        // over the smear duration to give the LPs their rewards over a period of time. Adding to utilizedReserves
        // acts to track these rewards after the smear duration. See _exchangeRateCurrent for more details.
        if (lpFeesCaptured > 0) {
            pooledTokens[l1Token].undistributedLpFees += lpFeesCaptured;
            pooledTokens[l1Token].utilizedReserves += int256(lpFeesCaptured);
        }

        // If there are any protocol fees, allocate them to the unclaimed protocol tracker amount.
        if (protocolFeesCaptured > 0) unclaimedAccumulatedProtocolFees[l1Token] += protocolFeesCaptured;
    }

    function _relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) internal {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;
        require(address(adapter) != address(0), "Adapter not initialized");

        // Perform delegatecall to use the adapter's code with this contract's context.
        (bool success, ) = address(adapter).delegatecall(
            abi.encodeWithSignature(
                "relayMessage(address,bytes)",
                crossChainContracts[chainId].spokePool, // target. This should be the spokePool on the L2.
                functionData
            )
        );
        require(success, "delegatecall failed");
        emit SpokePoolAdminFunctionTriggered(chainId, functionData);
    }

    function _whitelistedRouteKey(
        uint256 originChainId,
        address originToken,
        uint256 destinationChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(originChainId, originToken, destinationChainId));
    }

    function _activeRequest() internal view returns (bool) {
        return rootBundleProposal.unclaimedPoolRebalanceLeafCount != 0;
    }

    // If functionCallStackOriginatesFromOutsideThisContract is true then this was called by the callback function
    // by dropping ETH onto the contract. In this case, deposit the ETH into WETH. This would happen if ETH was sent
    // over the optimism bridge, for example. If false then this was set as a result of unwinding LP tokens, with the
    // intention of sending ETH to the LP. In this case, do nothing as we intend on sending the ETH to the LP.
    function _depositEthToWeth() internal {
        if (functionCallStackOriginatesFromOutsideThisContract()) weth.deposit{ value: msg.value }();
    }

    // Added to enable the HubPool to receive ETH. This will occur both when the HubPool unwraps WETH to send to LPs and
    // when ETH is send over the canonical Optimism bridge, which sends ETH.
    fallback() external payable {
        _depositEthToWeth();
    }

    receive() external payable {
        _depositEthToWeth();
    }
}
