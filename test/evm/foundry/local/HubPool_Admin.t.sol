// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { HubPoolTestBase, MockIdentifierWhitelist } from "../utils/HubPoolTestBase.sol";
import { Mock_Adapter } from "../../../../contracts/chain-adapters/Mock_Adapter.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { HubPool } from "../../../../contracts/HubPool.sol";

/**
 * @title HubPool_AdminTest
 * @notice Foundry tests for HubPool admin functions, migrated from HubPool.Admin.ts
 */
contract HubPool_AdminTest is HubPoolTestBase {
    // ============ Test Infrastructure ============

    Mock_Adapter mockAdapter;
    address mockSpoke;
    address otherUser;

    // ============ Constants ============

    uint256 constant DESTINATION_CHAIN_ID = 1342;

    // ============ Setup ============

    function setUp() public {
        // Create base fixture (deploys HubPool, WETH, tokens, UMA mocks)
        // Also sets liveness and identifier in the HubPool
        createHubPoolFixture();

        // Create test addresses
        otherUser = makeAddr("other");
        mockSpoke = makeAddr("mockSpoke");

        // Deploy Mock_Adapter
        mockAdapter = new Mock_Adapter();

        // Set up cross-chain contracts for destination chain
        fixture.hubPool.setCrossChainContracts(DESTINATION_CHAIN_ID, address(mockAdapter), mockSpoke);
    }

    // ============ enableL1TokenForLiquidityProvision Tests ============

    function test_EnableL1TokenForLiquidityProvision() public {
        // Before enabling, lpToken should be zero address
        (address lpTokenBefore, , , , , ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertEq(lpTokenBefore, address(0), "lpToken should be zero before enabling");

        // Enable the token
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // After enabling, verify the pooledTokens struct
        (address lpToken, bool isEnabled, uint32 lastLpFeeUpdate, , , ) = fixture.hubPool.pooledTokens(
            address(fixture.weth)
        );

        assertTrue(lpToken != address(0), "lpToken should not be zero after enabling");
        assertTrue(isEnabled, "isEnabled should be true");
        assertEq(lastLpFeeUpdate, block.timestamp, "lastLpFeeUpdate should be current time");

        // Verify LP token was created (using mock factory, so just verify it's a valid ERC20)
        MintableERC20 lpTokenContract = MintableERC20(lpToken);
        assertTrue(bytes(lpTokenContract.symbol()).length > 0, "LP token should have a symbol");
        assertTrue(bytes(lpTokenContract.name()).length > 0, "LP token should have a name");
    }

    function test_EnableL1Token_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
    }

    // ============ disableL1TokenForLiquidityProvision Tests ============

    function test_DisableL1TokenForLiquidityProvision() public {
        // First enable the token
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));

        // Get the LP token and lastLpFeeUpdate before disabling
        (address lpToken, , uint32 lastLpFeeUpdate, , , ) = fixture.hubPool.pooledTokens(address(fixture.weth));

        // Disable the token
        fixture.hubPool.disableL1TokenForLiquidityProvision(address(fixture.weth));

        // Verify isEnabled is false
        (, bool isEnabled, , , , ) = fixture.hubPool.pooledTokens(address(fixture.weth));
        assertFalse(isEnabled, "isEnabled should be false after disabling");

        // Re-enable and verify LP token is preserved
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));
        (address lpTokenAfter, bool isEnabledAfter, uint32 lastLpFeeUpdateAfter, , , ) = fixture.hubPool.pooledTokens(
            address(fixture.weth)
        );

        assertEq(lpTokenAfter, lpToken, "LP token should be preserved after re-enabling");
        assertEq(lastLpFeeUpdateAfter, lastLpFeeUpdate, "lastLpFeeUpdate should be preserved");
        assertTrue(isEnabledAfter, "isEnabled should be true after re-enabling");
    }

    function test_DisableL1Token_RevertsIfNotOwner() public {
        fixture.hubPool.enableL1TokenForLiquidityProvision(address(fixture.weth));

        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.disableL1TokenForLiquidityProvision(address(fixture.weth));
    }

    // ============ setCrossChainContracts Tests ============

    function test_SetCrossChainContracts_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setCrossChainContracts(DESTINATION_CHAIN_ID, address(mockAdapter), mockSpoke);
    }

    // ============ relaySpokePoolAdminFunction Tests ============

    function test_RelaySpokePoolAdminFunction_RevertsIfNotOwner() public {
        bytes memory functionData = abi.encodeWithSignature("pauseDeposits(bool)", true);

        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.relaySpokePoolAdminFunction(DESTINATION_CHAIN_ID, functionData);
    }

    function test_RelaySpokePoolAdminFunction_RevertsIfSpokeNotInitialized() public {
        bytes memory functionData = abi.encodeWithSignature("pauseDeposits(bool)", true);

        // Set spoke to zero address
        fixture.hubPool.setCrossChainContracts(DESTINATION_CHAIN_ID, address(mockAdapter), address(0));

        vm.expectRevert("SpokePool not initialized");
        fixture.hubPool.relaySpokePoolAdminFunction(DESTINATION_CHAIN_ID, functionData);
    }

    function test_RelaySpokePoolAdminFunction_RevertsIfAdapterNotInitialized() public {
        bytes memory functionData = abi.encodeWithSignature("pauseDeposits(bool)", true);

        // Set adapter to random address (non-contract)
        address randomAddr = makeAddr("random");
        fixture.hubPool.setCrossChainContracts(DESTINATION_CHAIN_ID, randomAddr, mockSpoke);

        vm.expectRevert("Adapter not initialized");
        fixture.hubPool.relaySpokePoolAdminFunction(DESTINATION_CHAIN_ID, functionData);
    }

    function test_RelaySpokePoolAdminFunction_EmitsEvent() public {
        bytes memory functionData = abi.encodeWithSignature("pauseDeposits(bool)", true);

        vm.expectEmit(address(fixture.hubPool));
        emit HubPool.SpokePoolAdminFunctionTriggered(DESTINATION_CHAIN_ID, functionData);

        fixture.hubPool.relaySpokePoolAdminFunction(DESTINATION_CHAIN_ID, functionData);
    }

    // ============ setBond Tests ============

    function test_SetBond() public {
        // Default bond is WETH (bondAmount = BOND_AMOUNT + FINAL_FEE for WETH)
        assertEq(address(fixture.hubPool.bondToken()), address(fixture.weth), "Default bond token should be WETH");
        assertEq(fixture.hubPool.bondAmount(), BOND_AMOUNT + FINAL_FEE, "Default bond amount mismatch");

        // Set bond to USDC with 1000 USDC
        // Note: setBond adds the final fee to the bond amount
        uint256 newBondAmount = 1000e6; // 1000 USDC
        uint256 usdcFinalFee = fixture.store.finalFees(address(fixture.usdc));
        fixture.hubPool.setBond(IERC20(address(fixture.usdc)), newBondAmount);

        assertEq(address(fixture.hubPool.bondToken()), address(fixture.usdc), "Bond token should be USDC");
        assertEq(
            fixture.hubPool.bondAmount(),
            newBondAmount + usdcFinalFee,
            "Bond amount should be 1001 USDC (1000 + finalFee)"
        );
    }

    function test_SetBond_RevertsIfZeroAmount() public {
        vm.expectRevert("bond equal to final fee");
        fixture.hubPool.setBond(IERC20(address(fixture.usdc)), 0);
    }

    function test_SetBond_RevertsIfPendingProposal() public {
        // Propose a root bundle
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = block.number;

        bytes32 mockRoot = keccak256("mockRoot");

        fixture.hubPool.proposeRootBundle(bundleEvaluationBlockNumbers, 5, mockRoot, mockRoot, mockRoot);

        // Attempt to change bond should revert
        vm.expectRevert("Proposal has unclaimed leaves");
        fixture.hubPool.setBond(IERC20(address(fixture.usdc)), 1000e6);
    }

    function test_SetBond_RevertsIfNotWhitelisted() public {
        address randomToken = makeAddr("randomToken");

        vm.expectRevert("Not on whitelist");
        fixture.hubPool.setBond(IERC20(randomToken), 1000);
    }

    function test_SetBond_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setBond(IERC20(address(fixture.usdc)), 1000e6);
    }

    // ============ setIdentifier Tests ============

    function test_SetIdentifier() public {
        bytes32 newIdentifier = bytes32("TEST_ID");

        // Add identifier to whitelist
        fixture.identifierWhitelist.addSupportedIdentifier(newIdentifier);

        // Set identifier
        fixture.hubPool.setIdentifier(newIdentifier);

        assertEq(fixture.hubPool.identifier(), newIdentifier, "Identifier should be updated");
    }

    function test_SetIdentifier_RevertsIfNotSupported() public {
        bytes32 unsupportedIdentifier = bytes32("UNSUPPORTED");

        vm.expectRevert("Identifier not supported");
        fixture.hubPool.setIdentifier(unsupportedIdentifier);
    }

    function test_SetIdentifier_RevertsIfNotOwner() public {
        bytes32 newIdentifier = bytes32("TEST_ID");
        fixture.identifierWhitelist.addSupportedIdentifier(newIdentifier);

        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setIdentifier(newIdentifier);
    }

    // ============ setLiveness Tests ============

    function test_SetLiveness() public {
        uint32 newLiveness = 1000000;

        fixture.hubPool.setLiveness(newLiveness);

        assertEq(fixture.hubPool.liveness(), newLiveness, "Liveness should be updated");
    }

    function test_SetLiveness_RevertsIfTooShort() public {
        vm.expectRevert("Liveness too short");
        fixture.hubPool.setLiveness(599);
    }

    function test_SetLiveness_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setLiveness(1000000);
    }

    // ============ setPaused Tests ============

    function test_SetPaused() public {
        vm.expectEmit(address(fixture.hubPool));
        emit HubPool.Paused(true);

        fixture.hubPool.setPaused(true);
    }

    function test_SetPaused_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.setPaused(true);
    }

    // ============ emergencyDeleteProposal Tests ============

    function test_EmergencyDeleteProposal_ClearsRootBundleProposal() public {
        // Propose a root bundle
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = block.number;

        bytes32 mockRoot = keccak256("mockRoot");

        fixture.hubPool.proposeRootBundle(bundleEvaluationBlockNumbers, 5, mockRoot, mockRoot, mockRoot);

        // Verify proposal exists (rootBundleProposal returns 7 elements)
        (, , , , , uint8 unclaimedCount, ) = fixture.hubPool.rootBundleProposal();
        assertEq(unclaimedCount, 5, "Unclaimed count should be 5");

        // Delete the proposal
        fixture.hubPool.emergencyDeleteProposal();

        // Verify proposal is cleared
        (, , , , , uint8 unclaimedCountAfter, ) = fixture.hubPool.rootBundleProposal();
        assertEq(unclaimedCountAfter, 0, "Unclaimed count should be 0 after delete");
    }

    function test_EmergencyDeleteProposal_ReturnsBond() public {
        // Get initial balances
        uint256 ownerWethBefore = fixture.weth.balanceOf(address(this));
        uint256 hubPoolWethBefore = fixture.weth.balanceOf(address(fixture.hubPool));

        // Propose a root bundle (bond is transferred to HubPool)
        uint256[] memory bundleEvaluationBlockNumbers = new uint256[](1);
        bundleEvaluationBlockNumbers[0] = block.number;

        bytes32 mockRoot = keccak256("mockRoot");

        fixture.hubPool.proposeRootBundle(bundleEvaluationBlockNumbers, 5, mockRoot, mockRoot, mockRoot);

        uint256 totalBond = fixture.hubPool.bondAmount();

        // Verify bond was taken
        assertEq(
            fixture.weth.balanceOf(address(fixture.hubPool)),
            hubPoolWethBefore + totalBond,
            "HubPool should have received bond"
        );

        // Delete the proposal
        fixture.hubPool.emergencyDeleteProposal();

        // Verify bond was returned
        assertEq(fixture.weth.balanceOf(address(this)), ownerWethBefore, "Owner should have bond returned");
        assertEq(
            fixture.weth.balanceOf(address(fixture.hubPool)),
            hubPoolWethBefore,
            "HubPool should have original balance"
        );
    }

    function test_EmergencyDeleteProposal_RevertsIfNotOwner() public {
        vm.prank(otherUser);
        vm.expectRevert("Ownable: caller is not the owner");
        fixture.hubPool.emergencyDeleteProposal();
    }

    function test_EmergencyDeleteProposal_SucceedsWithNoProposal() public {
        // Should not revert even with no proposal
        fixture.hubPool.emergencyDeleteProposal();
    }
}
