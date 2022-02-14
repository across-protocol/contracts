// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./HubPoolInterface.sol";
import "./interfaces/AdapterInterface.sol";
import "./interfaces/LpTokenFactoryInterface.sol";
import "./interfaces/WETH9.sol";

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";
import "@uma/core/contracts/common/implementation/AncillaryData.sol";

import "@uma/core/contracts/oracle/interfaces/FinderInterface.sol";
import "@uma/core/contracts/oracle/interfaces/StoreInterface.sol";
import "@uma/core/contracts/oracle/interfaces/SkinnyOptimisticOracleInterface.sol";
import "@uma/core/contracts/common/interfaces/ExpandedIERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract HubPool is HubPoolInterface, Testable, Lockable, MultiCaller, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    struct RefundRequest {
        uint64 requestExpirationTimestamp;
        uint64 unclaimedPoolRebalanceLeafCount;
        bytes32 poolRebalanceRoot;
        bytes32 destinationDistributionRoot;
        bytes32 slowRelayFulfillmentRoot;
        uint256 claimedBitMap; // This is a 1D bitmap, with max size of 256 elements, limiting us to 256 chainsIds.
        address proposer;
        bool proposerBondRepaid;
    }

    RefundRequest public refundRequest;

    // Whitelist of origin token to destination token routings to be used by off-chain agents. The notion of a route
    // does not need to include L1; it can store L2->L2 routes i.e USDC on Arbitrum -> USDC on Optimism as a "route".
    mapping(address => mapping(uint256 => address)) public whitelistedRoutes;

    // Mapping of L1TokenAddress to the associated Pool information.
    struct PooledToken {
        address lpToken;
        bool isEnabled;
        bool isWeth;
        uint32 lastLpFeeUpdate;
        int256 utilizedReserves;
        uint256 liquidReserves;
        uint256 undistributedLpFees;
    }

    mapping(address => PooledToken) public pooledTokens;

    struct CrossChainContract {
        AdapterInterface adapter;
        address spokePool;
    }

    mapping(uint256 => CrossChainContract) public crossChainContracts; // Mapping of chainId to the associated adapter and spokePool contracts.

    LpTokenFactoryInterface lpTokenFactory;

    FinderInterface public finder;

    // When bundles are disputed a price request is enqueued with the DVM to resolve the resolution.
    bytes32 public identifier = "IS_ACROSS_V2_BUNDLE_VALID";

    // Interest rate payment that scales the amount of pending fees per second paid to LPs. 0.0000015e18 will pay out
    // the full amount of fees entitled to LPs in ~ 7.72 days, just over the standard L2 7 day liveness.
    uint256 lpFeeRatePerSecond = 1500000000000;

    // Token used to bond the data worker for proposing relayer refund bundles.
    IERC20 public bondToken;

    // The computed bond amount as the UMA Store's final fee multiplied by the bondTokenFinalFeeMultiplier.
    uint256 public bondAmount;

    // Each refund proposal must stay in liveness for this period of time before it can be considered finalized. It can
    // be disputed only during this period of time. Defaults to 2 hours, like the rest of the UMA ecosystem.
    uint64 public refundProposalLiveness = 7200;

    event BondSet(address indexed newBondToken, uint256 newBondAmount);

    event RefundProposalLivenessSet(uint256 newRefundProposalLiveness);

    event IdentifierSet(bytes32 newIdentifier);

    event CrossChainContractsSet(uint256 l2ChainId, address adapter, address spokePool);

    event L1TokenEnabledForLiquidityProvision(address l1Token, bool isWeth, address lpToken);

    event L2TokenDisabledForLiquidityProvision(address l1Token, bool isWeth, address lpToken);

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
    event WhitelistRoute(uint256 destinationChainId, address originToken, address destinationToken);

    event InitiateRefundRequested(
        uint64 requestExpirationTimestamp,
        uint64 unclaimedPoolRebalanceLeafCount,
        uint256[] bundleEvaluationBlockNumbers,
        bytes32 indexed poolRebalanceRoot,
        bytes32 indexed destinationDistributionRoot,
        bytes32 slowRelayFulfillmentRoot,
        address indexed proposer
    );
    event RelayerRefundExecuted(
        uint256 indexed leafId,
        uint256 indexed chainId,
        address[] l1Token,
        uint256[] bundleLpFees,
        int256[] netSendAmount,
        int256[] runningBalance,
        address indexed caller
    );
    event SpokePoolAdminFunctionTriggered(uint256 indexed chainId, bytes message);

    event RelayerRefundDisputed(address indexed disputer, uint256 requestTime, bytes disputedAncillaryData);

    modifier noActiveRequests() {
        require(refundRequest.unclaimedPoolRebalanceLeafCount == 0, "Active request has unclaimed leafs");
        _;
    }

    constructor(
        LpTokenFactoryInterface _lpTokenFactory,
        FinderInterface _finder,
        address _timer
    ) Testable(_timer) {
        lpTokenFactory = _lpTokenFactory;
        finder = _finder;
    }

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

    function relaySpokePoolAdminFunction(uint256 chainId, bytes memory functionData) public onlyOwner nonReentrant {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;
        adapter.relayMessage(
            crossChainContracts[chainId].spokePool, // target. This should be the spokePool on the L2.
            functionData
        );
        emit SpokePoolAdminFunctionTriggered(chainId, functionData);
    }

    function setBond(IERC20 newBondToken, uint256 newBondAmount) public onlyOwner noActiveRequests {
        bondToken = newBondToken;
        bondAmount = newBondAmount;
        emit BondSet(address(newBondToken), newBondAmount);
    }

    function setRefundProposalLiveness(uint64 newRefundProposalLiveness) public onlyOwner {
        refundProposalLiveness = newRefundProposalLiveness;
        emit RefundProposalLivenessSet(newRefundProposalLiveness);
    }

    function setIdentifier(bytes32 newIdentifier) public onlyOwner {
        identifier = newIdentifier;
        emit IdentifierSet(newIdentifier);
    }

    function setCrossChainContracts(
        uint256 l2ChainId,
        address adapter,
        address spokePool
    ) public onlyOwner noActiveRequests {
        require(address(crossChainContracts[l2ChainId].adapter) == address(0), "Contract already set");
        crossChainContracts[l2ChainId] = CrossChainContract(AdapterInterface(adapter), spokePool);
        emit CrossChainContractsSet(l2ChainId, adapter, spokePool);
    }

    /**
     * @notice Whitelist an origin token <-> destination token route.
     */
    function whitelistRoute(
        uint256 destinationChainId,
        address originToken,
        address destinationToken
    ) public onlyOwner {
        whitelistedRoutes[originToken][destinationChainId] = destinationToken;
        relaySpokePoolAdminFunction(
            destinationChainId,
            abi.encodeWithSignature(
                "setEnableRoute(address,uint32,bool)",
                originToken,
                uint32(destinationChainId),
                true
            )
        );
        emit WhitelistRoute(destinationChainId, originToken, destinationToken);
    }

    function enableL1TokenForLiquidityProvision(address l1Token, bool isWeth) public onlyOwner {
        // NOTE: if we run out of bytecode this logic could be refactored into a custom token factory that does the
        // appends and permission setting.
        if (pooledTokens[l1Token].lpToken == address(0))
            pooledTokens[l1Token].lpToken = lpTokenFactory.createLpToken(l1Token);

        pooledTokens[l1Token].isEnabled = true;
        pooledTokens[l1Token].isWeth = isWeth;
        pooledTokens[l1Token].lastLpFeeUpdate = uint32(getCurrentTime());

        emit L1TokenEnabledForLiquidityProvision(l1Token, isWeth, pooledTokens[l1Token].lpToken);
    }

    function disableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        pooledTokens[l1Token].isEnabled = false;
        emit L2TokenDisabledForLiquidityProvision(l1Token, pooledTokens[l1Token].isWeth, pooledTokens[l1Token].lpToken);
    }

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    function addLiquidity(address l1Token, uint256 l1TokenAmount) public payable {
        require(pooledTokens[l1Token].isEnabled, "Token not enabled");
        // If this is the weth pool and the caller sends msg.value then the msg.value must match the l1TokenAmount.
        // Else, msg.value must be set to 0.
        require((pooledTokens[l1Token].isWeth && msg.value == l1TokenAmount) || msg.value == 0, "Bad msg.value");

        // Since _exchangeRateCurrent() reads this contract's balance and updates contract state using it, it must be
        // first before transferring any tokens to this contract to ensure synchronization.
        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / _exchangeRateCurrent(l1Token);
        ExpandedIERC20(pooledTokens[l1Token].lpToken).mint(msg.sender, lpTokensToMint);
        pooledTokens[l1Token].liquidReserves += l1TokenAmount;

        if (pooledTokens[l1Token].isWeth && msg.value > 0) WETH9(address(l1Token)).deposit{ value: msg.value }();
        else IERC20(l1Token).safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        emit LiquidityAdded(l1Token, l1TokenAmount, lpTokensToMint, msg.sender);
    }

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) public nonReentrant {
        require(pooledTokens[l1Token].isWeth || !sendEth, "Cant send eth");
        uint256 l1TokensToReturn = (lpTokenAmount * _exchangeRateCurrent(l1Token)) / 1e18;

        ExpandedIERC20(pooledTokens[l1Token].lpToken).burnFrom(msg.sender, lpTokenAmount);
        // Note this method does not make any liquidity utilization checks before letting the LP redeem their LP tokens.
        // If they try access more funds that available (i.e l1TokensToReturn > liquidReserves) this will underflow.
        pooledTokens[l1Token].liquidReserves -= l1TokensToReturn;

        if (sendEth) _unwrapWETHTo(l1Token, payable(msg.sender), l1TokensToReturn);
        else IERC20(l1Token).safeTransfer(msg.sender, l1TokensToReturn);

        emit LiquidityRemoved(l1Token, l1TokensToReturn, lpTokenAmount, msg.sender);
    }

    function exchangeRateCurrent(address l1Token) public nonReentrant returns (uint256) {
        return _exchangeRateCurrent(l1Token);
    }

    function liquidityUtilizationCurrent(address l1Token) public nonReentrant returns (uint256) {
        return _liquidityUtilizationPostRelay(l1Token, 0);
    }

    function liquidityUtilizationPostRelay(address l1Token, uint256 relayedAmount)
        public
        nonReentrant
        returns (uint256)
    {
        return _liquidityUtilizationPostRelay(l1Token, relayedAmount);
    }

    function sync(address l1Token) public nonReentrant {
        _sync(l1Token);
    }

    /*************************************************
     *             DATA WORKER FUNCTIONS             *
     *************************************************/

    // After initiateRelayerRefund is called, if the any props are wrong then this proposal can be challenged. Once the
    // challenge period passes, then the roots are no longer disputable, and only executeRelayerRefund can be called and
    // initiateRelayerRefund can't be called again until all leafs are executed.
    function initiateRelayerRefund(
        uint256[] memory bundleEvaluationBlockNumbers,
        uint64 poolRebalanceLeafCount,
        bytes32 poolRebalanceRoot,
        bytes32 destinationDistributionRoot,
        bytes32 slowRelayFulfillmentRoot
    ) public noActiveRequests {
        require(poolRebalanceLeafCount > 0, "Bundle must have at least 1 leaf");

        uint64 requestExpirationTimestamp = uint64(getCurrentTime() + refundProposalLiveness);

        delete refundRequest; // Remove the existing information relating to the previous relayer refund request.

        refundRequest.requestExpirationTimestamp = requestExpirationTimestamp;
        refundRequest.unclaimedPoolRebalanceLeafCount = poolRebalanceLeafCount;
        refundRequest.poolRebalanceRoot = poolRebalanceRoot;
        refundRequest.destinationDistributionRoot = destinationDistributionRoot;
        refundRequest.slowRelayFulfillmentRoot = slowRelayFulfillmentRoot;
        refundRequest.proposer = msg.sender;

        // Pull bondAmount of bondToken from the caller.
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        emit InitiateRefundRequested(
            requestExpirationTimestamp,
            poolRebalanceLeafCount,
            bundleEvaluationBlockNumbers,
            poolRebalanceRoot,
            destinationDistributionRoot,
            slowRelayFulfillmentRoot,
            msg.sender
        );
    }

    function executeRelayerRefund(PoolRebalanceLeaf memory poolRebalanceLeaf, bytes32[] memory proof) public {
        require(getCurrentTime() >= refundRequest.requestExpirationTimestamp, "Not passed liveness");

        // Verify the leafId in the poolRebalanceLeaf has not yet been claimed.
        require(!MerkleLib.isClaimed1D(refundRequest.claimedBitMap, poolRebalanceLeaf.leafId), "Already claimed");

        // Verify the props provided generate a leaf that, along with the proof, are included in the merkle root.
        require(MerkleLib.verifyPoolRebalance(refundRequest.poolRebalanceRoot, poolRebalanceLeaf, proof), "Bad Proof");

        // Set the leafId in the claimed bitmap.
        refundRequest.claimedBitMap = MerkleLib.setClaimed1D(refundRequest.claimedBitMap, poolRebalanceLeaf.leafId);

        // Decrement the unclaimedPoolRebalanceLeafCount.
        refundRequest.unclaimedPoolRebalanceLeafCount--;

        _sendTokensToChainAndUpdatePooledTokenTrackers(
            poolRebalanceLeaf.chainId,
            poolRebalanceLeaf.l1Tokens,
            poolRebalanceLeaf.netSendAmounts,
            poolRebalanceLeaf.bundleLpFees
        );
        _executeRelayerRefundOnChain(poolRebalanceLeaf.chainId);

        // Transfer the bondAmount to back to the proposer, if this the last executed leaf. Only sending this once all
        // leafs have been executed acts to force the data worker to execute all bundles or they wont receive their bond.
        //TODO: consider if we want to reward the proposer. if so, this is where we should do it.
        if (refundRequest.unclaimedPoolRebalanceLeafCount == 0)
            bondToken.safeTransfer(refundRequest.proposer, bondAmount);

        emit RelayerRefundExecuted(
            poolRebalanceLeaf.leafId,
            poolRebalanceLeaf.chainId,
            poolRebalanceLeaf.l1Tokens,
            poolRebalanceLeaf.bundleLpFees,
            poolRebalanceLeaf.netSendAmounts,
            poolRebalanceLeaf.runningBalances,
            msg.sender
        );
    }

    function disputeRelayerRefund() public {
        require(getCurrentTime() <= refundRequest.requestExpirationTimestamp, "Request passed liveness");

        // Request price from OO and dispute it.
        uint256 totalBond = _getBondTokenFinalFee() + bondAmount;
        bytes memory requestAncillaryData = _getRefundProposalAncillaryData();
        bondToken.safeTransferFrom(msg.sender, address(this), totalBond);
        // This contract needs to approve totalBond*2 against the OO contract. (for the price request and dispute).
        bondToken.safeApprove(address(_getOptimisticOracle()), totalBond * 2);
        _getOptimisticOracle().requestAndProposePriceFor(
            identifier,
            uint32(getCurrentTime()),
            requestAncillaryData,
            bondToken,
            // Set reward to 0, since we'll settle proposer reward payouts directly from this contract after a relay
            // proposal has passed the challenge period.
            0,
            // Set the Optimistic oracle proposer bond for the price request.
            bondAmount,
            // Set the Optimistic oracle liveness for the price request.
            refundProposalLiveness,
            refundRequest.proposer,
            // Canonical value representing "True"; i.e. the proposed relay is valid.
            int256(1e18)
        );

        // Dispute the request that we just sent.
        SkinnyOptimisticOracleInterface.Request memory ooPriceRequest = SkinnyOptimisticOracleInterface.Request({
            proposer: refundRequest.proposer,
            disputer: address(0),
            currency: bondToken,
            settled: false,
            proposedPrice: int256(1e18),
            resolvedPrice: 0,
            expirationTime: getCurrentTime() + refundProposalLiveness,
            reward: 0,
            finalFee: _getBondTokenFinalFee(),
            bond: bondAmount,
            customLiveness: refundProposalLiveness
        });

        _getOptimisticOracle().disputePriceFor(
            identifier,
            uint32(getCurrentTime()),
            requestAncillaryData,
            ooPriceRequest,
            msg.sender,
            address(this)
        );

        emit RelayerRefundDisputed(msg.sender, getCurrentTime(), requestAncillaryData);

        // Finally, delete the state pertaining to the active refundRequest.
        delete refundRequest;
    }

    function _getRefundProposalAncillaryData() public view returns (bytes memory ancillaryData) {
        ancillaryData = AncillaryData.appendKeyValueUint(
            "",
            "requestExpirationTimestamp",
            refundRequest.requestExpirationTimestamp
        );

        ancillaryData = AncillaryData.appendKeyValueUint(
            ancillaryData,
            "unclaimedPoolRebalanceLeafCount",
            refundRequest.unclaimedPoolRebalanceLeafCount
        );
        ancillaryData = AncillaryData.appendKeyValueBytes32(
            ancillaryData,
            "poolRebalanceRoot",
            refundRequest.poolRebalanceRoot
        );
        ancillaryData = AncillaryData.appendKeyValueBytes32(
            ancillaryData,
            "destinationDistributionRoot",
            refundRequest.destinationDistributionRoot
        );
        ancillaryData = AncillaryData.appendKeyValueUint(ancillaryData, "claimedBitMap", refundRequest.claimedBitMap);
        ancillaryData = AncillaryData.appendKeyValueAddress(ancillaryData, "proposer", refundRequest.proposer);
    }

    /*************************************************
     *              INTERNAL FUNCTIONS               *
     *************************************************/

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends WETH.
    function _unwrapWETHTo(
        address wethAddress,
        address payable to,
        uint256 amount
    ) internal {
        if (address(to).isContract()) {
            IERC20(address(wethAddress)).safeTransfer(to, amount);
        } else {
            WETH9(wethAddress).withdraw(amount);
            to.transfer(amount);
        }
    }

    function _append(
        string memory a,
        string memory b,
        string memory c
    ) internal pure returns (string memory) {
        return string(abi.encodePacked(a, b, c));
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
    // is done as a gas saving so we don't need to iterate over the l1Tokens multiple times (can do both in one loop).
    function _sendTokensToChainAndUpdatePooledTokenTrackers(
        uint256 chainId,
        address[] memory l1Tokens,
        int256[] memory netSendAmounts,
        uint256[] memory bundleLpFees
    ) internal {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;
        require(address(adapter) != address(0), "Adapter not set for target chain");

        for (uint32 i = 0; i < l1Tokens.length; i++) {
            // Validate the L1 -> L2 token route is whitelisted. If it is not then the output of the bridging action
            // could send tokens to the 0x0 address on the L2.
            require(whitelistedRoutes[l1Tokens[i]][chainId] != address(0), "Route not whitelisted");

            // If the net send amount for this token is positive then: 1) send tokens from L1->L2 to facilitate the L2
            // relayer refund, 2) Update the liquidity trackers for the associated pooled tokens.
            if (netSendAmounts[i] > 0) {
                IERC20(l1Tokens[i]).safeTransfer(address(adapter), uint256(netSendAmounts[i]));
                adapter.relayTokens(
                    l1Tokens[i], // l1Token.
                    whitelistedRoutes[l1Tokens[i]][chainId], // l2Token.
                    uint256(netSendAmounts[i]), // amount.
                    crossChainContracts[chainId].spokePool // to. This should be the spokePool.
                );

                // Liquid reserves is decreased by the amount sent. utilizedReserves is increased by the amount sent.
                pooledTokens[l1Tokens[i]].utilizedReserves += netSendAmounts[i];
                pooledTokens[l1Tokens[i]].liquidReserves -= uint256(netSendAmounts[i]);
            }

            // Assign any LP fees included into the bundle to the pooled token. These LP fees are tracked in the
            // undistributedLpFees and within the utilizedReserves. undistributedLpFees is gradually decrease
            // over the smear duration to give the LPs their rewards over a period of time. Adding to utilizedReserves
            // acts to track these rewards after the smear duration. See _exchangeRateCurrent for more details.
            pooledTokens[l1Tokens[i]].undistributedLpFees += bundleLpFees[i];
            pooledTokens[l1Tokens[i]].utilizedReserves += int256(bundleLpFees[i]);
        }
    }

    function _executeRelayerRefundOnChain(uint256 chainId) internal {
        AdapterInterface adapter = crossChainContracts[chainId].adapter;
        adapter.relayMessage(
            crossChainContracts[chainId].spokePool, // target. This should be the spokePool on the L2.
            abi.encodeWithSignature(
                "initializeRelayerRefund(bytes32,bytes32)",
                refundRequest.destinationDistributionRoot,
                refundRequest.slowRelayFulfillmentRoot
            ) // message
        );
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
        // accumulatedFees := min(undistributedLpFees * lpFeeRatePerSecond * timeFromLastInteraction ,undistributedLpFees)
        // The min acts to pay out all fees in the case the equation returns more than the remaining a fees.
        uint256 timeFromLastInteraction = getCurrentTime() - lastLpFeeUpdate;
        uint256 maxUndistributedLpFees = (undistributedLpFees * lpFeeRatePerSecond * timeFromLastInteraction) / (1e18);
        return maxUndistributedLpFees < undistributedLpFees ? maxUndistributedLpFees : undistributedLpFees;
    }

    function _sync(address l1Token) internal {
        // Check if the l1Token balance of the contract is greater than the liquidReserves. If it is then the bridging
        // action from L2 -> L1 has concluded and the local accounting can be updated.
        uint256 l1TokenBalance = IERC20(l1Token).balanceOf(address(this));
        if (l1TokenBalance > pooledTokens[l1Token].liquidReserves) {
            // Note the numerical operation below can send utilizedReserves to negative. This can occur when tokens are
            // dropped onto the contract, exceeding the liquidReserves.
            pooledTokens[l1Token].utilizedReserves -= int256(l1TokenBalance - pooledTokens[l1Token].liquidReserves);
            pooledTokens[l1Token].liquidReserves = l1TokenBalance;
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

    // Added to enable the SpokePool to receive ETH. used when unwrapping WETH.
    receive() external payable {}
}
