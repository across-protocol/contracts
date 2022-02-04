// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";
import "./chain-adapters/AdapterInterface.sol";

import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/Lockable.sol";
import "@uma/core/contracts/common/implementation/MultiCaller.sol";
import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";
import "@uma/core/contracts/common/implementation/AncillaryData.sol";

import "@uma/core/contracts/oracle/interfaces/FinderInterface.sol";
import "@uma/core/contracts/oracle/interfaces/StoreInterface.sol";
import "@uma/core/contracts/oracle/interfaces/SkinnyOptimisticOracleInterface.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface WETH9Like {
    function withdraw(uint256 wad) external;

    function deposit() external payable;
}

contract HubPool is Testable, Lockable, MultiCaller, Ownable {
    using SafeERC20 for IERC20;
    using Address for address;

    struct RefundRequest {
        uint64 requestExpirationTimestamp;
        uint64 unclaimedPoolRebalanceLeafCount;
        bytes32 poolRebalanceRoot;
        bytes32 destinationDistributionRoot;
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
        uint256 liquidReserves;
        uint256 utilizedReserves;
        uint256 undistributedLpFees;
        uint256 lockedBonds;
        uint32 lastLpFeeUpdate;
        bool isWeth;
    }

    mapping(address => PooledToken) public pooledTokens;

    struct CrossChainContract {
        AdapterInterface adapter;
        address spokePool;
    }

    mapping(uint256 => CrossChainContract) public crossChainContracts; // Mapping of chainId to the associated adapter and spokePool contracts.

    FinderInterface public finder;

    // When bundles are disputed a price request is enqueued with the DVM to resolve the resolution.
    bytes32 public identifier = "IS_ACROSS_V2_BUNDLE_VALID";

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

    event L2TokenForPooledTokenSet(uint256 l2ChainId, address l1Token, address l2Token);

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
        bytes32 poolRebalanceRoot,
        bytes32 destinationDistributionRoot,
        address indexed proposer
    );
    event RelayerRefundExecuted(
        uint256 relayerRefundId,
        uint256 leafId,
        uint256 chainId,
        address[] l1Token,
        uint256[] bundleLpFees,
        int256[] netSendAmount,
        int256[] runningBalance,
        address caller
    );

    event RelayerRefundDisputed(address indexed disputer, uint256 requestTime, bytes disputedAncillaryData);

    modifier noActiveRequests() {
        require(refundRequest.unclaimedPoolRebalanceLeafCount == 0, "Active request has unclaimed leafs");
        _;
    }

    constructor(FinderInterface _finder, address _timer) Testable(_timer) {
        finder = _finder;
    }

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

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
        emit WhitelistRoute(destinationChainId, originToken, destinationToken);
    }

    function enableL1TokenForLiquidityProvision(address l1Token, bool isWeth) public onlyOwner {
        // NOTE: if we run out of bytecode this logic could be refactored into a custom token factory that does the
        // appends and permission setting.
        if (pooledTokens[l1Token].lpToken == address(0)) {
            ExpandedERC20 lpToken = new ExpandedERC20(
                _append("Across ", IERC20Metadata(l1Token).name(), " LP Token"), // LP Token Name
                _append("Av2-", IERC20Metadata(l1Token).symbol(), "-LP"), // LP Token Symbol
                IERC20Metadata(l1Token).decimals() // LP Token Decimals
            );
            lpToken.addMember(1, address(this)); // Set this contract as the LP Token's minter.
            lpToken.addMember(2, address(this)); // Set this contract as the LP Token's burner.
            pooledTokens[l1Token].lpToken = address(lpToken);
        }
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

        // Since `exchangeRateCurrent()` reads this contract's balance and updates contract state using it,
        // we must call it first before transferring any tokens to this contract.
        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / _exchangeRateCurrent();
        ExpandedERC20(pooledTokens[l1Token].lpToken).mint(msg.sender, lpTokensToMint);
        pooledTokens[l1Token].liquidReserves += l1TokenAmount;

        if (pooledTokens[l1Token].isWeth && msg.value > 0) WETH9Like(address(l1Token)).deposit{ value: msg.value }();
        else IERC20(l1Token).safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        emit LiquidityAdded(l1Token, l1TokenAmount, lpTokensToMint, msg.sender);
    }

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) public nonReentrant {
        // Can only send eth on withdrawing liquidity iff this is the WETH pool.
        require(pooledTokens[l1Token].isWeth || !sendEth, "Cant send eth");
        uint256 l1TokensToReturn = (lpTokenAmount * _exchangeRateCurrent()) / 1e18;

        ExpandedERC20(pooledTokens[l1Token].lpToken).burnFrom(msg.sender, lpTokenAmount);
        pooledTokens[l1Token].liquidReserves -= l1TokensToReturn;

        if (sendEth) _unwrapWETHTo(l1Token, payable(msg.sender), l1TokensToReturn);
        else IERC20(l1Token).safeTransfer(msg.sender, l1TokensToReturn);

        emit LiquidityRemoved(l1Token, l1TokensToReturn, lpTokenAmount, msg.sender);
    }

    function exchangeRateCurrent() public nonReentrant returns (uint256) {
        return _exchangeRateCurrent();
    }

    function liquidityUtilizationPostRelay(address token, uint256 relayedAmount) public returns (uint256) {}

    /*************************************************
     *             DATA WORKER FUNCTIONS             *
     *************************************************/

    function initiateRelayerRefund(
        uint256[] memory bundleEvaluationBlockNumbers,
        uint64 poolRebalanceLeafCount,
        bytes32 poolRebalanceRoot,
        bytes32 destinationDistributionRoot
    ) public noActiveRequests {
        require(poolRebalanceLeafCount > 0, "Bundle must have at least 1 leaf");

        uint64 requestExpirationTimestamp = uint64(getCurrentTime() + refundProposalLiveness);

        delete refundRequest; // Remove the existing information relating to the previous relayer refund request.

        refundRequest.requestExpirationTimestamp = requestExpirationTimestamp;
        refundRequest.unclaimedPoolRebalanceLeafCount = poolRebalanceLeafCount;
        refundRequest.poolRebalanceRoot = poolRebalanceRoot;
        refundRequest.destinationDistributionRoot = destinationDistributionRoot;
        refundRequest.proposer = msg.sender;

        // Pull bondAmount of bondToken from the caller.
        bondToken.safeTransferFrom(msg.sender, address(this), bondAmount);

        emit InitiateRefundRequested(
            requestExpirationTimestamp,
            poolRebalanceLeafCount,
            bundleEvaluationBlockNumbers,
            poolRebalanceRoot,
            destinationDistributionRoot,
            msg.sender
        );
    }

    function executeRelayerRefund(MerkleLib.PoolRebalance memory poolRebalance, bytes32[] memory proof) public {
        require(getCurrentTime() >= refundRequest.requestExpirationTimestamp, "Not passed liveness");

        // Verify the leafId in the poolRebalance has not yet been claimed.
        require(!MerkleLib.isClaimed1D(refundRequest.claimedBitMap, poolRebalance.leafId), "Already claimed");

        // Verify the props provided generate a leaf that, along with the proof, are included in the merkle root.
        require(MerkleLib.verifyPoolRebalance(refundRequest.poolRebalanceRoot, poolRebalance, proof), "Bad Proof");

        // Set the leafId in the claimed bitmap.
        refundRequest.claimedBitMap = MerkleLib.setClaimed1D(refundRequest.claimedBitMap, poolRebalance.leafId);

        // Decrement the unclaimedPoolRebalanceLeafCount.
        refundRequest.unclaimedPoolRebalanceLeafCount--;

        // Transfer the bondAmount to back to the proposer, if this the last executed leaf. Only sending this once all
        // leafs have been executed acts to force the data worker to execute all bundles or they wont receive their bond.
        //TODO: consider if we want to reward the proposer. if so, this is where we should do it.
        if (refundRequest.unclaimedPoolRebalanceLeafCount == 0)
            bondToken.safeTransfer(refundRequest.proposer, bondAmount);

        _sendTokensToTargetChain(poolRebalance);
        _executeRelayerRefundOnTargetChain(poolRebalance);

        // TODO: modify the associated utilized and pending reserves for each token sent.

        emit RelayerRefundExecuted(
            poolRebalance.leafId,
            poolRebalance.chainId,
            poolRebalance.l1Token,
            poolRebalance.bundleLpFees,
            poolRebalance.netSendAmount,
            poolRebalance.runningBalance,
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

    function _exchangeRateCurrent() internal pure returns (uint256) {
        // TODO: implement this method to consider utilization.
        return 1e18;
    }

    // Unwraps ETH and does a transfer to a recipient address. If the recipient is a smart contract then sends WETH.
    function _unwrapWETHTo(
        address wethAddress,
        address payable to,
        uint256 amount
    ) internal {
        if (address(to).isContract()) {
            IERC20(address(wethAddress)).safeTransfer(to, amount);
        } else {
            WETH9Like(wethAddress).withdraw(amount);
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

    function _sendTokensToTargetChain(MerkleLib.PoolRebalance memory poolRebalance) internal {
        AdapterInterface adapter = crossChainContracts[poolRebalance.chainId].adapter;
        require(address(adapter) != address(0), "Adapter not set for target chain");

        for (uint32 i = 0; i < poolRebalance.l1Token.length; i++) {
            // Validate the output L2 token is correctly whitelisted.
            address l2Token = whitelistedRoutes[poolRebalance.l1Token[i]][poolRebalance.chainId];
            require(l2Token != address(0), "L2 token not set for L1 token");

            int256 amount = poolRebalance.netSendAmount[i];

            // TODO: Checking the amount is greater than 0 is not sufficient. we need to build an external library that
            // makes the decision on if there should be an L1->L2 token transfer. this should come in a later PR.
            if (amount > 0) {
                // Send the adapter all the tokens it needs to bridge. This should be refined later to remove the extra
                // token transfer through the use of delegate call.
                IERC20(poolRebalance.l1Token[i]).safeApprove(address(adapter), uint256(amount));
                adapter.relayTokens(
                    poolRebalance.l1Token[i], // l1Token
                    l2Token, // l2Token
                    uint256(amount), // amount
                    crossChainContracts[poolRebalance.chainId].spokePool // to. This should be the spokePool.
                );
            }
        }
    }

    function _executeRelayerRefundOnTargetChain(MerkleLib.PoolRebalance memory poolRebalance) internal {
        AdapterInterface adapter = crossChainContracts[poolRebalance.chainId].adapter;
        adapter.relayMessage(
            crossChainContracts[poolRebalance.chainId].spokePool, // target. This should be the spokePool.
            abi.encodeWithSignature("initializeRelayerRefund(bytes32)", refundRequest.destinationDistributionRoot) // message
        );
    }

    function _updatePooledTokenForExecutedRebalance(MerkleLib.PoolRebalance memory poolRebalance) internal {
        for (uint32 i = 0; i < poolRebalance.l1Token.length; i++) {
            pooledTokens[poolRebalance.l1Token[i]].undistributedLpFees += poolRebalance.bundleLpFees[i];
            if (poolRebalance.netSendAmount[i] > 0) {
                pooledTokens[poolRebalance.l1Token[i]].liquidReserves -= uint256(poolRebalance.netSendAmount[i]);
                pooledTokens[poolRebalance.l1Token[i]].utilizedReserves += uint256(poolRebalance.netSendAmount[i]);
            }
        }
    }

    // Added to enable the BridgePool to receive ETH. used when unwrapping Weth.
    receive() external payable {}
}
