// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import "./MerkleLib.sol";

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
    struct LPToken {
        ExpandedERC20 lpToken;
        bool isEnabled;
    }

    struct RefundRequest {
        uint64 requestExpirationTimestamp;
        uint64 unclaimedPoolRebalanceLeafCount;
        bytes32 poolRebalanceRoot;
        bytes32 destinationDistributionRoot;
        uint256 claimedBitMap;
        address proposer;
        bool proposerBondRepaid;
    }

    RefundRequest public refundRequest;

    // Whitelist of origin token to destination token routings to be used by off-chain agents.
    mapping(address => mapping(uint256 => address)) public whitelistedRoutes;

    mapping(address => LPToken) public lpTokens; // Mapping of L1TokenAddress to the associated LPToken.

    FinderInterface public finder;

    bytes32 public identifier;

    // Token used to bond the data worker for proposing relayer refund bundles.
    IERC20 public bondToken;

    // The computed bond amount as the UMA Store's final fee multiplied by the bondTokenFinalFeeMultiplier.
    uint256 public bondAmount;

    // Address of L1Weth. Enable LPs to deposit/receive ETH, if they choose, when adding/removing liquidity.
    WETH9Like public l1Weth;

    // Each refund proposal must stay in liveness for this period of time before it can be considered finalized. It can
    // be disputed only during this period of time.
    uint64 public refundProposalLiveness;

    event BondSet(address newBondToken, uint256 newBondAmount);

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
    event WhitelistRoute(address originToken, uint256 destinationChainId, address destinationToken);

    event InitiateRefundRequested(
        uint64 requestExpirationTimestamp,
        uint64 unclaimedPoolRebalanceLeafCount,
        uint256[] bundleEvaluationBlockNumbers,
        bytes32 poolRebalanceRoot,
        bytes32 destinationDistributionRoot,
        address indexed proposer
    );
    event RelayerRefundExecuted(uint256 relayerRefundId, MerkleLib.PoolRebalance poolRebalance, address caller);

    event RelayerRefundDisputed(
        address disputer,
        SkinnyOptimisticOracleInterface.Request ooPriceRequest,
        RefundRequest refundRequest
    );

    modifier onlyIfNoActiveRequest() {
        require(refundRequest.unclaimedPoolRebalanceLeafCount == 0, "Active request has unclaimed leafs");
        _;
    }

    constructor(
        uint256 _bondAmount,
        uint64 _refundProposalLiveness,
        FinderInterface _finder,
        bytes32 _identifier,
        IERC20 _bondToken,
        WETH9Like _l1Weth,
        address _timer
    ) Testable(_timer) {
        bondAmount = _bondAmount;
        refundProposalLiveness = _refundProposalLiveness;
        bondToken = _bondToken;
        l1Weth = _l1Weth;
        finder = _finder;
        identifier = _identifier;
    }

    /*************************************************
     *                ADMIN FUNCTIONS                *
     *************************************************/

    function setBond(IERC20 newBondToken, uint256 newBondAmount) public onlyOwner onlyIfNoActiveRequest {
        bondToken = newBondToken;
        bondAmount = newBondAmount;
        emit BondSet(address(newBondToken), newBondAmount);
    }

    /**
     * @notice Whitelist an origin token <-> destination token route.
     */
    function whitelistRoute(
        address originToken,
        address destinationToken,
        uint256 destinationChainId
    ) public onlyOwner {
        whitelistedRoutes[originToken][destinationChainId] = destinationToken;

        emit WhitelistRoute(originToken, destinationChainId, destinationToken);
    }

    // TODO: the two functions below should be called by the Admin contract.
    function enableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        // NOTE: if we run out of bytecode this logic could be refactored into a custom token factory that does the
        // appends and permission setting.
        ExpandedERC20 lpToken = new ExpandedERC20(
            _append("Across ", IERC20Metadata(l1Token).name(), " LP Token"), // LP Token Name
            _append("Av2-", IERC20Metadata(l1Token).symbol(), "-LP"), // LP Token Symbol
            IERC20Metadata(l1Token).decimals() // LP Token Decimals
        );
        lpToken.addMember(1, address(this)); // Set this contract as the LP Token's minter.
        lpToken.addMember(2, address(this)); // Set this contract as the LP Token's burner.
        lpTokens[l1Token] = LPToken({ lpToken: lpToken, isEnabled: true });
    }

    function disableL1TokenForLiquidityProvision(address l1Token) public onlyOwner {
        lpTokens[l1Token].isEnabled = false;
    }

    // TODO: implement this. this will likely go into a separate Admin contract that contains all the L1->L2 Admin logic.
    // function setTokenToAcceptDeposits(address token) public {}

    /*************************************************
     *          LIQUIDITY PROVIDER FUNCTIONS         *
     *************************************************/

    function addLiquidity(address l1Token, uint256 l1TokenAmount) public payable {
        require(lpTokens[l1Token].isEnabled, "Token not enabled");
        // If this is the weth pool and the caller sends msg.value then the msg.value must match the l1TokenAmount.
        // Else, msg.value must be set to 0.
        require((address(l1Token) == address(l1Weth) && msg.value == l1TokenAmount) || msg.value == 0, "Bad msg.value");

        // Since `exchangeRateCurrent()` reads this contract's balance and updates contract state using it,
        // we must call it first before transferring any tokens to this contract.
        uint256 lpTokensToMint = (l1TokenAmount * 1e18) / _exchangeRateCurrent();
        ExpandedERC20(lpTokens[l1Token].lpToken).mint(msg.sender, lpTokensToMint);
        // liquidReserves += l1TokenAmount; //TODO: Add this when we have the liquidReserves variable implemented.

        if (address(l1Token) == address(l1Weth) && msg.value > 0)
            WETH9Like(address(l1Token)).deposit{ value: msg.value }();
        else IERC20(l1Token).safeTransferFrom(msg.sender, address(this), l1TokenAmount);

        emit LiquidityAdded(l1Token, l1TokenAmount, lpTokensToMint, msg.sender);
    }

    function removeLiquidity(
        address l1Token,
        uint256 lpTokenAmount,
        bool sendEth
    ) public nonReentrant {
        // Can only send eth on withdrawing liquidity iff this is the WETH pool.
        require(l1Token == address(l1Weth) || !sendEth, "Cant send eth");
        uint256 l1TokensToReturn = (lpTokenAmount * _exchangeRateCurrent()) / 1e18;

        // Check that there is enough liquid reserves to withdraw the requested amount.
        // require(liquidReserves >= (pendingReserves + l1TokensToReturn), "Utilization too high to remove"); // TODO: add this when we have liquid reserves variable implemented.

        ExpandedERC20(lpTokens[l1Token].lpToken).burnFrom(msg.sender, lpTokenAmount);
        // liquidReserves -= l1TokensToReturn; // TODO: add this when we have liquid reserves variable implemented.

        if (sendEth) _unwrapWETHTo(payable(msg.sender), l1TokensToReturn);
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
    ) public onlyIfNoActiveRequest {
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

    function executeRelayerRefund(
        uint256 relayerRefundRequestId,
        MerkleLib.PoolRebalance memory poolRebalance,
        bytes32[] memory proof
    ) public {
        require(getCurrentTime() >= refundRequest.requestExpirationTimestamp, "Not passed liveness");

        // Verify the leafId in the poolRebalance has not yet been claimed.
        require(!MerkleLib.isClaimed1D(refundRequest.claimedBitMap, poolRebalance.leafId), "Already claimed");

        // Verify the props provided generate a leaf that, along with the proof, are included in the merkle root.
        require(MerkleLib.verifyPoolRebalance(refundRequest.poolRebalanceRoot, poolRebalance, proof), "Bad Proof");

        // Set the leafId in the claimed bitmap.
        refundRequest.claimedBitMap = MerkleLib.setClaimed1D(refundRequest.claimedBitMap, poolRebalance.leafId);

        // Decrement the unclaimedPoolRebalanceLeafCount.
        refundRequest.unclaimedPoolRebalanceLeafCount--;

        // Transfer the bondAmount to back to the proposer, if this was not done before for this refund bundle.
        if (!refundRequest.proposerBondRepaid) {
            refundRequest.proposerBondRepaid = true;
            bondToken.safeTransfer(refundRequest.proposer, bondAmount);
        }

        // TODO call into canonical bridge to send PoolRebalance.netSendAmount for the associated
        // PoolRebalance.tokenAddresses, to the target PoolRebalance.chainId. this will likely happen within a
        // x_Messenger contract for each chain. these messengers will be registered in a separate process that will follow
        // in a later PR.
        // TODO: modify the associated utilized and pending reserves for each token sent.

        emit RelayerRefundExecuted(relayerRefundRequestId, poolRebalance, msg.sender);
    }

    function disputeRelayerRefund() public {
        require(getCurrentTime() <= refundRequest.requestExpirationTimestamp, "Request passed liveness");

        // Request price from OO and dispute it.
        uint256 totalBond = _getBondTokenFinalFee() + bondAmount;
        bondToken.safeTransferFrom(msg.sender, address(this), totalBond);
        // This contract needs to approve totalBond*2 against the OO contract. (for the price request and dispute).
        bondToken.safeApprove(address(_getOptimisticOracle()), totalBond * 2);
        _getOptimisticOracle().requestAndProposePriceFor(
            identifier,
            uint32(getCurrentTime()),
            _getRefundProposalAncillaryData(),
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
            _getRefundProposalAncillaryData(),
            ooPriceRequest,
            msg.sender,
            address(this)
        );

        emit RelayerRefundDisputed(msg.sender, ooPriceRequest, refundRequest);

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
    function _unwrapWETHTo(address payable to, uint256 amount) internal {
        if (address(to).isContract()) {
            IERC20(address(l1Weth)).safeTransfer(to, amount);
        } else {
            l1Weth.withdraw(amount);
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

    // Added to enable the BridgePool to receive ETH. used when unwrapping Weth.
    receive() external payable {}
}
