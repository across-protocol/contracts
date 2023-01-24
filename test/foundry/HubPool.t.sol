pragma solidity >=0.8.0;

import { PRBTest } from "@prb/test/PRBTest.sol";
import "forge-std/console.sol";
import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "@uma/core/contracts/oracle/implementation/Finder.sol";
import "@uma/core/contracts/oracle/implementation/Store.sol";

import "./Utilities.sol";
import "./mocks/MockWETH9.sol";
import "./mocks/MockAddressWhitelist.sol";
import "../../contracts/LpTokenFactory.sol";
import "../../contracts/HubPool.sol";

contract HubPoolTest is PRBTest {
    Utilities internal utils;
    address payable[] internal users;
    address internal admin;
    address internal dataworker;

    HubPool public hubPool;
    ExpandedERC20 public bondToken;
    LpTokenFactory public lpTokenFactory;
    MockWETH9 public weth;

    // UMA set up:
    Finder public finder;
    MockAddressWhitelist public whitelist;
    Store public store;

    function setUp() public {
        utils = new Utilities();
        users = utils.createUsers(2);
        admin = users[0];
        dataworker = users[1];
        vm.startPrank(admin);

        bondToken = new ExpandedERC20("name", "symbol", 18);
        bondToken.addMember(1, admin);
        bondToken.mint(dataworker, 1000e18);
        lpTokenFactory = new LpTokenFactory();
        weth = new MockWETH9();

        // Set up UMA system. TODO: Move this to a common UMASetup contract.
        finder = new Finder();
        whitelist = new MockAddressWhitelist();
        store = new Store(FixedPoint.fromUnscaledUint(0), FixedPoint.fromUnscaledUint(0), address(0));
        finder.changeImplementationAddress(OracleInterfaces.Store, address(store));
        finder.changeImplementationAddress(OracleInterfaces.CollateralWhitelist, address(whitelist));
        whitelist.addToWhitelist(address(bondToken));
        hubPool = new HubPool(lpTokenFactory, finder, weth, address(0));
        vm.stopPrank();
    }

    function test_setBond() external {
        vm.startPrank(dataworker);
        vm.expectRevert("Ownable: caller is not the owner");
        hubPool.setBond(bondToken, 1e18);
        vm.stopPrank();
    }

    function testFuzz_setBond(uint256 amount) external {
        vm.assume(amount > 0);
        vm.prank(admin);
        hubPool.setBond(bondToken, amount);
    }

    function test_proposeRootBundle() external {
        vm.prank(admin);
        hubPool.setBond(bondToken, 1e18);

        vm.startPrank(dataworker);
        bondToken.increaseAllowance(address(hubPool), 1e18);
        uint256[] memory bundleBlockRange = new uint256[](1);
        bundleBlockRange[0] = 1;
        hubPool.proposeRootBundle(
            bundleBlockRange,
            1,
            keccak256("randomroot"),
            keccak256("randomroot"),
            keccak256("randomroot")
        );
        vm.stopPrank();

        (, , , , , , uint32 challengePeriodEndTimestamp) = hubPool.rootBundleProposal();
        assertEq(hubPool.getCurrentTime() + 2 hours, challengePeriodEndTimestamp);

        // Demonstrate time warping feature of forge:
        assertFalse(hubPool.getCurrentTime() >= challengePeriodEndTimestamp);
        vm.warp(challengePeriodEndTimestamp);
        assertTrue(hubPool.getCurrentTime() >= challengePeriodEndTimestamp);
    }
}
