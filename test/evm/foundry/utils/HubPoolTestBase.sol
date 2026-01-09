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
import { Constants } from "../../../../script/utils/Constants.sol";

import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

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
    MockIdentifierWhitelist identifierWhitelist;
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
        data.identifierWhitelist = new MockIdentifierWhitelist();
        data.store = new MockStore();

        // Configure finder with UMA ecosystem addresses
        data.finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(data.addressWhitelist));
        data.finder.changeImplementationAddress(
            OracleInterfaces.IdentifierWhitelist,
            address(data.identifierWhitelist)
        );
        data.finder.changeImplementationAddress(OracleInterfaces.Store, address(data.store));

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
}
