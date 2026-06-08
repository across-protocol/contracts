// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract WithdrawImplementationTest is CounterfactualTestBase {
    MintableERC20 public token;

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        _setUpCore();
        _deployBeacon(_baseConfig());
        token = new MintableERC20("USDC", "USDC", 6);
    }

    function _deployCloneWithWithdrawLeaf(
        bytes memory withdrawParams
    ) internal returns (address clone, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(withdrawImpl), withdrawParams);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        clone = factory.deploy(keccak256("salt"), root);
    }

    // --- ERC20 withdraw tests ---

    function testERC20WithdrawByUser() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), user, 100e6),
            proof
        );

        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    function testERC20WithdrawByAdmin() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), admin, 100e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), admin, 100e6),
            proof
        );

        assertEq(token.balanceOf(admin), 100e6);
    }

    function testERC20WithdrawToOtherRecipient() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), relayer, 100e6),
            proof
        );

        assertEq(token.balanceOf(relayer), 100e6);
    }

    function testUnauthorizedCallerReverts() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer); // not admin or user
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), relayer, 100e6),
            proof
        );
    }

    function testPartialWithdraw() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        // First partial withdraw
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(address(withdrawImpl), wp, abi.encode(address(token), user, 30e6), proof);
        assertEq(token.balanceOf(user), 30e6);
        assertEq(token.balanceOf(clone), 70e6);

        // Second partial withdraw
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(address(withdrawImpl), wp, abi.encode(address(token), user, 70e6), proof);
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    // --- Native ETH withdraw tests ---

    function testNativeETHWithdraw() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        vm.deal(clone, 1 ether);

        uint256 userBalBefore = user.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(NATIVE_ASSET, user, 1 ether);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(NATIVE_ASSET, user, 1 ether),
            proof
        );

        assertEq(user.balance - userBalBefore, 1 ether);
        assertEq(clone.balance, 0);
    }

    function testNativeETHWithdrawByAdmin() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        vm.deal(clone, 1 ether);

        uint256 adminBalBefore = admin.balance;

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(NATIVE_ASSET, admin, 1 ether),
            proof
        );

        assertEq(admin.balance - adminBalBefore, 1 ether);
    }

    // --- Single-leaf withdraw tree (both callers share one leaf) ---

    function testBothCallersShareOneLeaf() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 200e6);

        // User withdraws 100
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), user, 100e6),
            proof
        );

        // Admin withdraws 100
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), admin, 100e6),
            proof
        );

        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(admin), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }
}
