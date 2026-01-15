// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { HubPool } from "../../../../contracts/HubPool.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { LpTokenFactoryInterface } from "../../../../contracts/interfaces/LpTokenFactoryInterface.sol";
import { FinderInterface } from "../../../../contracts/external/uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { OracleInterfaces } from "../../../../contracts/external/uma/core/contracts/data-verification-mechanism/implementation/Constants.sol";
import { Timer } from "../../../../contracts/external/uma/core/contracts/common/implementation/Timer.sol";
import { SkinnyOptimisticOracleInterface } from "../../../../contracts/external/uma/core/contracts/optimistic-oracle-v2/interfaces/SkinnyOptimisticOracleInterface.sol";
import { OptimisticOracleInterface } from "../../../../contracts/external/uma/core/contracts/optimistic-oracle-v2/interfaces/OptimisticOracleInterface.sol";
import { Constants } from "../../../../script/utils/Constants.sol";

import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";

// ============ UMA Ecosystem Mocks ============

/**
 * @title MockLpTokenFactory
 * @notice Factory that creates MintableERC20 instances for HubPool.
 */
contract MockLpTokenFactory is LpTokenFactoryInterface {
    function createLpToken(address) external override returns (address) {
        return address(new MintableERC20("LP Token", "LPT", 18));
    }
}

/**
 * @title MockFinder
 * @notice Minimal UMA Finder mock for registering interface addresses.
 */
contract MockFinder is FinderInterface {
    mapping(bytes32 => address) public interfaces;

    function changeImplementationAddress(bytes32 interfaceName, address implementationAddress) external override {
        interfaces[interfaceName] = implementationAddress;
    }

    function getImplementationAddress(bytes32 interfaceName) external view override returns (address) {
        return interfaces[interfaceName];
    }
}

/**
 * @title MockAddressWhitelist
 * @notice Mock collateral whitelist that tracks whitelisted addresses.
 */
contract MockAddressWhitelist {
    mapping(address => bool) private _whitelist;

    function addToWhitelist(address token) external {
        _whitelist[token] = true;
    }

    function removeFromWhitelist(address token) external {
        _whitelist[token] = false;
    }

    function isOnWhitelist(address token) external view returns (bool) {
        return _whitelist[token];
    }

    function getWhitelist() external pure returns (address[] memory) {
        return new address[](0);
    }
}

/**
 * @title MockIdentifierWhitelist
 * @notice Mock identifier whitelist for testing setIdentifier.
 */
contract MockIdentifierWhitelist {
    mapping(bytes32 => bool) public supportedIdentifiers;

    function addSupportedIdentifier(bytes32 identifier) external {
        supportedIdentifiers[identifier] = true;
    }

    function removeSupportedIdentifier(bytes32 identifier) external {
        supportedIdentifiers[identifier] = false;
    }

    function isIdentifierSupported(bytes32 identifier) external view returns (bool) {
        return supportedIdentifiers[identifier];
    }
}

/**
 * @title MockStore
 * @notice Mock UMA Store with configurable final fees.
 */
contract MockStore {
    struct FinalFee {
        uint256 rawValue;
    }

    mapping(address => uint256) public finalFees;

    function setFinalFee(address token, FinalFee memory fee) external {
        finalFees[token] = fee.rawValue;
    }

    function payOracleFees() external payable {}
    function payOracleFeesErc20(address, uint256) external {}

    function computeFinalFee(address token) external view returns (FinalFee memory) {
        return FinalFee(finalFees[token]);
    }
}

/**
 * @title MockOptimisticOracle
 * @notice Mock of UMA's SkinnyOptimisticOracle matching the real implementation behavior.
 * @dev This mock replicates the real oracle's behavior for testing dispute functionality.
 *      Inherits from SkinnyOptimisticOracleInterface to ensure correct function signatures.
 */
contract MockOptimisticOracle is SkinnyOptimisticOracleInterface {
    uint256 public defaultLiveness;
    MockStore public store;

    // Store requests by their ID (we use our own storage, not the interface's)
    mapping(bytes32 => Request) public requests;

    constructor(uint256 _defaultLiveness, MockStore _store) {
        defaultLiveness = _defaultLiveness;
        store = _store;
    }

    // ============ Implemented Functions ============

    function requestAndProposePriceFor(
        bytes32 identifier,
        uint32 timestamp,
        bytes memory ancillaryData,
        IERC20 currency,
        uint256 /* reward */,
        uint256 bond,
        uint256 customLiveness,
        address proposer,
        int256 proposedPrice
    ) external override returns (uint256 totalBond) {
        bytes32 requestId = keccak256(abi.encode(msg.sender, identifier, timestamp, ancillaryData));

        // Get final fee from store (matching real oracle behavior)
        uint256 finalFee = store.computeFinalFee(address(currency)).rawValue;

        // Pull bond + finalFee from caller (matching real oracle: bond + finalFee)
        totalBond = bond + finalFee;
        currency.transferFrom(msg.sender, address(this), totalBond);

        requests[requestId] = Request({
            proposer: proposer,
            disputer: address(0),
            currency: currency,
            settled: false,
            proposedPrice: proposedPrice,
            resolvedPrice: 0,
            expirationTime: block.timestamp + customLiveness,
            reward: 0,
            finalFee: finalFee,
            bond: bond,
            customLiveness: customLiveness
        });

        return totalBond;
    }

    function disputePriceFor(
        bytes32 identifier,
        uint32 timestamp,
        bytes memory ancillaryData,
        Request memory request,
        address disputer,
        address requester
    ) public override returns (uint256 totalBond) {
        bytes32 requestId = keccak256(abi.encode(requester, identifier, timestamp, ancillaryData));
        Request storage storedRequest = requests[requestId];

        // Pull full bondAmount from disputer (bond + finalFee from the Request parameter)
        // This matches what HubPool approves: bondAmount = bond + finalFee
        // Matching real oracle: totalBond = request.requestSettings.bond.add(request.finalFee)
        totalBond = request.bond + request.finalFee;
        storedRequest.currency.transferFrom(msg.sender, address(this), totalBond);

        // Compute burned bond: floor(bond / 2)
        // Matching real oracle: _computeBurnedBond()
        uint256 burnedBond = request.bond / 2;

        // The total fee is the burned bond and the final fee added together
        // Matching real oracle: totalFee = request.finalFee.add(burnedBond)
        uint256 totalFee = request.finalFee + burnedBond;

        // Send totalFee to store (matching real oracle behavior)
        if (totalFee > 0) {
            storedRequest.currency.transfer(address(store), totalFee);
            store.payOracleFeesErc20(address(storedRequest.currency), totalFee);
        }

        // Update stored request with disputer
        storedRequest.disputer = disputer;

        return totalBond;
    }

    // ============ Stub Functions (not used in tests but required by interface) ============

    function requestPrice(
        bytes32,
        uint32,
        bytes memory,
        IERC20,
        uint256,
        uint256,
        uint256
    ) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function proposePriceFor(
        address,
        bytes32,
        uint32,
        bytes memory,
        Request memory,
        address,
        int256
    ) public pure override returns (uint256) {
        revert("Not implemented");
    }

    function proposePrice(
        address,
        bytes32,
        uint32,
        bytes memory,
        Request memory,
        int256
    ) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function disputePrice(
        address,
        bytes32,
        uint32,
        bytes memory,
        Request memory
    ) external pure override returns (uint256) {
        revert("Not implemented");
    }

    function settle(
        address,
        bytes32,
        uint32,
        bytes memory,
        Request memory
    ) external pure override returns (uint256, int256) {
        revert("Not implemented");
    }

    function getState(
        address,
        bytes32,
        uint32,
        bytes memory,
        Request memory
    ) external pure override returns (OptimisticOracleInterface.State) {
        revert("Not implemented");
    }

    function hasPrice(address, bytes32, uint32, bytes memory, Request memory) public pure override returns (bool) {
        revert("Not implemented");
    }

    function stampAncillaryData(bytes memory, address) public pure override returns (bytes memory) {
        revert("Not implemented");
    }
}

// ============ Fixture Data Struct ============

/**
 * @title HubPoolFixtureData
 * @notice Contains all deployed contracts and addresses from the fixture.
 */
struct HubPoolFixtureData {
    // Core contracts
    HubPool hubPool;
    WETH9 weth;
    // Tokens
    MintableERC20 dai;
    MintableERC20 usdc;
    MintableERC20 usdt;
    // UMA ecosystem mocks
    Timer timer;
    MockLpTokenFactory lpTokenFactory;
    MockFinder finder;
    MockAddressWhitelist addressWhitelist;
    MockIdentifierWhitelist identifierWhitelist;
    MockStore store;
    MockOptimisticOracle optimisticOracle;
    // L2 token addresses
    address l2Weth;
    address l2Dai;
    address l2Usdc;
    address l2Usdt;
}

/**
 * @title HubPoolTestBase
 * @notice Base test contract providing HubPool fixture setup similar to Hardhat fixtures.
 * @dev Extend this contract in your tests and call `createHubPoolFixture()` in setUp().
 *      Inherits from Constants to provide access to chain IDs, Circle domains, OFT EIDs, etc.
 */
abstract contract HubPoolTestBase is Test, Constants {
    // ============ Constants ============

    uint256 public constant BOND_AMOUNT = 5 ether;
    uint256 public constant FINAL_FEE = 1 ether;
    uint256 public constant TOTAL_BOND = BOND_AMOUNT + FINAL_FEE;
    uint256 public constant INITIAL_ETH = 100 ether;
    uint256 public constant LP_ETH_FUNDING = 10 ether;
    uint32 public constant REFUND_PROPOSAL_LIVENESS = 7200; // 2 hours
    bytes32 public constant DEFAULT_IDENTIFIER = bytes32("ACROSS-V2");

    // Common test amounts
    uint256 public constant AMOUNT_TO_LP = 1000 ether;

    // Mock roots for bundle proposals
    bytes32 public constant MOCK_POOL_REBALANCE_ROOT = bytes32(uint256(0xabc));
    bytes32 public constant MOCK_RELAYER_REFUND_ROOT = bytes32(uint256(0x1234));
    bytes32 public constant MOCK_SLOW_RELAY_ROOT = bytes32(uint256(0x5678));

    // ============ Internal Storage ============

    HubPoolFixtureData internal fixture;

    // ============ Fixture Creation ============

    /**
     * @notice Deploys and configures a HubPool with all necessary mocks.
     * @dev Call this in your setUp() function. The caller becomes the owner.
     *      This mimics the Hardhat UmaEcosystem.Fixture + HubPool.Fixture setup.
     * @return data The fixture data containing all deployed contracts
     */
    function createHubPoolFixture() internal returns (HubPoolFixtureData memory data) {
        // Deploy Timer for time control (matches UmaEcosystem.Fixture)
        data.timer = new Timer();

        // Deploy UMA ecosystem mocks
        data.lpTokenFactory = new MockLpTokenFactory();
        data.finder = new MockFinder();
        data.addressWhitelist = new MockAddressWhitelist();
        data.identifierWhitelist = new MockIdentifierWhitelist();
        data.store = new MockStore();

        // Deploy OptimisticOracle with liveness * 10 (matches UmaEcosystem.Fixture)
        // Pass store reference so oracle can distribute final fees (matching real oracle)
        data.optimisticOracle = new MockOptimisticOracle(REFUND_PROPOSAL_LIVENESS * 10, data.store);

        // Configure finder with UMA ecosystem addresses
        data.finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(data.addressWhitelist));
        data.finder.changeImplementationAddress(
            OracleInterfaces.IdentifierWhitelist,
            address(data.identifierWhitelist)
        );
        data.finder.changeImplementationAddress(OracleInterfaces.Store, address(data.store));
        data.finder.changeImplementationAddress(
            OracleInterfaces.SkinnyOptimisticOracle,
            address(data.optimisticOracle)
        );

        // Add supported identifier (matches UmaEcosystem.Fixture)
        data.identifierWhitelist.addSupportedIdentifier(DEFAULT_IDENTIFIER);

        // Deploy WETH and tokens
        data.weth = new WETH9();
        data.dai = new MintableERC20("DAI", "DAI", 18);
        data.usdc = new MintableERC20("USDC", "USDC", 6);
        data.usdt = new MintableERC20("USDT", "USDT", 6);

        // Whitelist tokens for collateral (required for bond token)
        data.addressWhitelist.addToWhitelist(address(data.weth));
        data.addressWhitelist.addToWhitelist(address(data.dai));
        data.addressWhitelist.addToWhitelist(address(data.usdc));
        data.addressWhitelist.addToWhitelist(address(data.usdt));

        // Set final fees for tokens (matches HubPool.Fixture)
        data.store.setFinalFee(address(data.weth), MockStore.FinalFee({ rawValue: FINAL_FEE }));
        data.store.setFinalFee(address(data.dai), MockStore.FinalFee({ rawValue: FINAL_FEE }));
        data.store.setFinalFee(address(data.usdc), MockStore.FinalFee({ rawValue: 1e6 })); // 1 USDC
        data.store.setFinalFee(address(data.usdt), MockStore.FinalFee({ rawValue: 1e6 })); // 1 USDT

        // Create L2 token addresses
        data.l2Weth = makeAddr("l2Weth");
        data.l2Dai = makeAddr("l2Dai");
        data.l2Usdc = makeAddr("l2Usdc");
        data.l2Usdt = makeAddr("l2Usdt");

        // Deploy HubPool without Timer - use vm.warp() for time control in Foundry
        // Timer is still available in fixture.timer if needed for other purposes
        data.hubPool = new HubPool(
            data.lpTokenFactory,
            data.finder,
            WETH9Interface(address(data.weth)),
            address(0) // Use block.timestamp, controlled via vm.warp()
        );

        // Set bond token (will add FINAL_FEE to get total bond)
        data.hubPool.setBond(IERC20(address(data.weth)), BOND_AMOUNT);

        // Set liveness
        data.hubPool.setLiveness(REFUND_PROPOSAL_LIVENESS);

        // Fund caller with ETH and WETH for bond
        vm.deal(address(this), INITIAL_ETH);
        data.weth.deposit{ value: INITIAL_ETH / 2 }();
        data.weth.approve(address(data.hubPool), type(uint256).max);

        // Fund HubPool with ETH for L2 calls
        vm.deal(address(data.hubPool), LP_ETH_FUNDING);

        // Store in internal storage for convenience
        fixture = data;

        return data;
    }

    /**
     * @notice Enables a token for LP and sets up pool rebalance route.
     * @param chainId The destination chain ID
     * @param l1Token The L1 token address
     * @param l2Token The L2 token address
     */
    function enableToken(uint256 chainId, address l1Token, address l2Token) internal {
        fixture.hubPool.setPoolRebalanceRoute(chainId, l1Token, l2Token);
        fixture.hubPool.enableL1TokenForLiquidityProvision(l1Token);
    }

    /**
     * @notice Adds liquidity for a token to the HubPool.
     * @param token The token to provide liquidity for
     * @param amount The amount of liquidity to add
     */
    function addLiquidity(MintableERC20 token, uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(fixture.hubPool), amount);
        fixture.hubPool.addLiquidity(address(token), amount);
    }

    /**
     * @notice Proposes a root bundle and warps past liveness period.
     * @param poolRebalanceRoot The pool rebalance merkle root
     * @param relayerRefundRoot The relayer refund merkle root (use bytes32(0) if not needed)
     * @param slowRelayRoot The slow relay merkle root (use bytes32(0) if not needed)
     */
    function proposeAndExecuteBundle(
        bytes32 poolRebalanceRoot,
        bytes32 relayerRefundRoot,
        bytes32 slowRelayRoot
    ) internal {
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = block.number;

        fixture.hubPool.proposeRootBundle(
            bundleEvaluationBlockNumbers,
            1,
            poolRebalanceRoot,
            relayerRefundRoot,
            slowRelayRoot
        );

        // Warp past liveness period
        vm.warp(block.timestamp + fixture.hubPool.liveness() + 1);
    }

    /**
     * @notice Proposes a root bundle and warps past liveness period.
     * @param poolRebalanceRoot The pool rebalance merkle root
     * @param relayerRefundRoot The relayer refund merkle root
     * @param slowRelayRoot The slow relay merkle root
     */
    function proposeBundleAndAdvanceTime(
        bytes32 poolRebalanceRoot,
        bytes32 relayerRefundRoot,
        bytes32 slowRelayRoot
    ) internal {
        proposeAndExecuteBundle(poolRebalanceRoot, relayerRefundRoot, slowRelayRoot);
    }

    /**
     * @notice Executes a pool rebalance leaf from a root bundle.
     * @param leaf The pool rebalance leaf to execute
     * @param proof The merkle proof for the leaf
     */
    function executeLeaf(HubPoolInterface.PoolRebalanceLeaf memory leaf, bytes32[] memory proof) internal {
        fixture.hubPool.executeRootBundle(
            leaf.chainId,
            leaf.groupIndex,
            leaf.bundleLpFees,
            leaf.netSendAmounts,
            leaf.runningBalances,
            leaf.leafId,
            leaf.l1Tokens,
            proof
        );
    }

    /**
     * @notice Seeds a user with ETH and WETH.
     * @param user The address to seed
     * @param amount The amount of ETH/WETH to seed
     */
    function seedUserWithWeth(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        fixture.weth.deposit{ value: amount }();
    }

    /**
     * @notice Sets up token routes for a destination chain.
     * @param chainId The destination chain ID
     * @param l2Weth The L2 WETH address
     * @param l2Dai The L2 DAI address
     * @param l2Usdc The L2 USDC address
     */
    function setupTokenRoutes(uint256 chainId, address l2Weth, address l2Dai, address l2Usdc) internal {
        fixture.hubPool.setPoolRebalanceRoute(chainId, address(fixture.weth), l2Weth);
        fixture.hubPool.setPoolRebalanceRoute(chainId, address(fixture.dai), l2Dai);
        fixture.hubPool.setPoolRebalanceRoute(chainId, address(fixture.usdc), l2Usdc);

        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.dai));
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.usdc));
    }
}
