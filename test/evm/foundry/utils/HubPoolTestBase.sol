// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { HubPool } from "../../../../contracts/HubPool.sol";
import { HubPoolInterface } from "../../../../contracts/interfaces/HubPoolInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { LpTokenFactoryInterface } from "../../../../contracts/interfaces/LpTokenFactoryInterface.sol";
import { FinderInterface } from "../../../../contracts/external/uma/core/contracts/data-verification-mechanism/interfaces/FinderInterface.sol";
import { OracleInterfaces } from "../../../../contracts/external/uma/core/contracts/data-verification-mechanism/implementation/Constants.sol";
import { Constants } from "../../../../script/utils/Constants.sol";

import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { MockSpokePool } from "../../../../contracts/test/MockSpokePool.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { MerkleTreeUtils } from "./MerkleTreeUtils.sol";

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
 * @notice Mock collateral whitelist that approves all tokens.
 */
contract MockAddressWhitelist {
    function addToWhitelist(address) external {}
    function removeFromWhitelist(address) external {}
    function isOnWhitelist(address) external pure returns (bool) {
        return true;
    }
    function getWhitelist() external pure returns (address[] memory) {
        return new address[](0);
    }
}

/**
 * @title MockStore
 * @notice Mock UMA Store that returns zero final fees.
 */
contract MockStore {
    struct FinalFee {
        uint256 rawValue;
    }

    function payOracleFees() external payable {}
    function payOracleFeesErc20(address, uint256) external {}
    function computeFinalFee(address) external pure returns (FinalFee memory) {
        return FinalFee(0);
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
    // UMA mocks
    MockLpTokenFactory lpTokenFactory;
    MockFinder finder;
    MockAddressWhitelist addressWhitelist;
    MockStore store;
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
    uint256 public constant INITIAL_ETH = 100 ether;
    uint256 public constant LP_ETH_FUNDING = 10 ether;

    // ============ Common Test Amounts ============

    uint256 public constant TOKENS_TO_SEND = 100 ether;
    uint256 public constant LP_FEES = 10 ether;
    uint256 public constant USDC_TO_SEND = 100e6; // USDC has 6 decimals
    uint256 public constant USDC_LP_FEES = 10e6;
    uint256 public constant USDT_TO_SEND = 100e6; // USDT has 6 decimals
    uint256 public constant USDT_LP_FEES = 10e6;
    uint256 public constant BURN_LIMIT = 1_000_000e6; // 1M USDC per message

    // ============ Common Mock Roots ============

    bytes32 public constant MOCK_TREE_ROOT = keccak256("mockTreeRoot");
    bytes32 public constant MOCK_RELAYER_REFUND_ROOT = keccak256("mockRelayerRefundRoot");
    bytes32 public constant MOCK_SLOW_RELAY_ROOT = keccak256("mockSlowRelayRoot");

    // ============ Internal Storage ============

    HubPoolFixtureData internal fixture;

    // ============ Fixture Creation ============

    /**
     * @notice Deploys and configures a HubPool with all necessary mocks.
     * @dev Call this in your setUp() function. The caller becomes the owner.
     * @return data The fixture data containing all deployed contracts
     */
    function createHubPoolFixture() internal returns (HubPoolFixtureData memory data) {
        // Deploy UMA ecosystem mocks
        data.lpTokenFactory = new MockLpTokenFactory();
        data.finder = new MockFinder();
        data.addressWhitelist = new MockAddressWhitelist();
        data.store = new MockStore();

        // Configure finder with UMA ecosystem addresses
        data.finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(data.addressWhitelist));
        data.finder.changeImplementationAddress(OracleInterfaces.Store, address(data.store));

        // Deploy WETH and tokens
        data.weth = new WETH9();
        data.dai = new MintableERC20("DAI", "DAI", 18);
        data.usdc = new MintableERC20("USDC", "USDC", 6);
        data.usdt = new MintableERC20("USDT", "USDT", 6);

        // Create L2 token addresses
        data.l2Weth = makeAddr("l2Weth");
        data.l2Dai = makeAddr("l2Dai");
        data.l2Usdc = makeAddr("l2Usdc");
        data.l2Usdt = makeAddr("l2Usdt");

        // Deploy HubPool
        data.hubPool = new HubPool(data.lpTokenFactory, data.finder, WETH9Interface(address(data.weth)), address(0));

        // Set bond token
        data.hubPool.setBond(IERC20(address(data.weth)), BOND_AMOUNT);

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
    function proposeBundleAndAdvanceTime(
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

    // ============ MockSpokePool Deployment ============

    /**
     * @notice Deploys a MockSpokePool with UUPS proxy pattern.
     * @param crossDomainAdmin The cross-domain admin address for the spoke pool
     * @return The deployed MockSpokePool instance
     */
    function deployMockSpokePool(address crossDomainAdmin) internal returns (MockSpokePool) {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(new MockSpokePool(address(fixture.weth))),
            abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, address(fixture.hubPool)))
        );
        return MockSpokePool(payable(proxy));
    }

    // ============ Token Route Setup ============

    /**
     * @notice Sets up standard token routes (WETH, DAI, USDC) for a given chain.
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

    /**
     * @notice Sets up standard token routes including USDT for a given chain.
     * @param chainId The destination chain ID
     * @param l2Weth The L2 WETH address
     * @param l2Dai The L2 DAI address
     * @param l2Usdc The L2 USDC address
     * @param l2Usdt The L2 USDT address
     */
    function setupTokenRoutesWithUsdt(
        uint256 chainId,
        address l2Weth,
        address l2Dai,
        address l2Usdc,
        address l2Usdt
    ) internal {
        setupTokenRoutes(chainId, l2Weth, l2Dai, l2Usdc);
        fixture.hubPool.setPoolRebalanceRoute(chainId, address(fixture.usdt), l2Usdt);
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.usdt));
    }

    // ============ WETH Liquidity Helpers ============

    /**
     * @notice Adds WETH liquidity while handling the bond requirement.
     * @dev WETH tests require extra funds because the HubPool uses WETH for bond.
     *      This helper ensures there's enough WETH for both liquidity and bond.
     * @param amount The amount of WETH liquidity to add
     */
    function addWethLiquidityWithBond(uint256 amount) internal {
        uint256 wethNeeded = amount + BOND_AMOUNT;
        vm.deal(address(this), wethNeeded);
        fixture.weth.deposit{ value: wethNeeded }();
        fixture.weth.approve(address(fixture.hubPool), type(uint256).max);
        fixture.hubPool.addLiquidity(address(fixture.weth), amount);
    }

    // ============ Root Bundle Execution ============

    /**
     * @notice Full flow: build merkle leaf, propose, advance time, and execute root bundle.
     * @param chainId The destination chain ID
     * @param l1Token The L1 token to bridge
     * @param amount The amount to send
     * @param lpFees The LP fees
     * @param relayerRefundRoot The relayer refund root (use MOCK_RELAYER_REFUND_ROOT or bytes32(0))
     * @param slowRelayRoot The slow relay root (use MOCK_SLOW_RELAY_ROOT or bytes32(0))
     * @return leaf The executed pool rebalance leaf
     */
    function executeRootBundleForToken(
        uint256 chainId,
        address l1Token,
        uint256 amount,
        uint256 lpFees,
        bytes32 relayerRefundRoot,
        bytes32 slowRelayRoot
    ) internal returns (HubPoolInterface.PoolRebalanceLeaf memory leaf) {
        bytes32 root;
        (leaf, root) = MerkleTreeUtils.buildSingleTokenLeaf(chainId, l1Token, amount, lpFees);

        proposeBundleAndAdvanceTime(root, relayerRefundRoot, slowRelayRoot);

        bytes32[] memory proof = MerkleTreeUtils.emptyProof();
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

    // ============ vm.etch Helper ============

    /**
     * @notice Puts dummy bytecode at an address to pass extcodesize checks.
     * @dev Use this when mocking external contracts with vm.mockCall.
     *      Without code, calls to the address will revert due to Solidity's extcodesize check.
     * @param target The address to put dummy code at
     */
    function etchDummyCode(address target) internal {
        vm.etch(target, hex"00");
    }

    /**
     * @notice Creates a fake address and puts dummy bytecode at it.
     * @dev Combines makeAddr and vm.etch for convenience.
     * @param name The name for the address (used by makeAddr)
     * @return target The created address with dummy code
     */
    function makeFakeContract(string memory name) internal returns (address target) {
        target = makeAddr(name);
        vm.etch(target, hex"00");
    }
}
