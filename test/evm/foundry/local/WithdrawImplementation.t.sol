// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation, WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract WithdrawImplementationTest is Test {
    Merkle public merkle;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositFactory public factory;
    WithdrawImplementation public withdrawImpl;
    MintableERC20 public token;

    address public user;
    address public admin;
    address public relayer;

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        merkle = new Merkle();
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        withdrawImpl = new WithdrawImplementation();
        token = new MintableERC20("USDC", "USDC", 6);

        user = makeAddr("user");
        admin = makeAddr("admin");
        relayer = makeAddr("relayer");
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(implementation, keccak256(params)));
    }

    function _deployCloneWithWithdrawLeaf(
        bytes memory withdrawParams
    ) internal returns (address clone, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(withdrawImpl), withdrawParams);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        clone = factory.deploy(address(dispatcher), root, keccak256("salt"));
    }

    // --- ERC20 withdraw tests ---

    function testERC20Withdraw() public {
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
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

    function testERC20WithdrawToOtherRecipient() public {
        // forcedRecipient == address(0), so any recipient is allowed
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
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
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer); // not the authorized caller
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), relayer, 100e6),
            proof
        );
    }

    function testForcedRecipientEnforced() public {
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: admin, forcedRecipient: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        token.mint(clone, 100e6);

        // Trying to send to admin instead of forced user recipient
        vm.expectRevert(WithdrawImplementation.InvalidRecipient.selector);
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), admin, 100e6), // wrong recipient
            proof
        );

        // Correct recipient works
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), user, 100e6),
            proof
        );
        assertEq(token.balanceOf(user), 100e6);
    }

    function testPartialWithdraw() public {
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
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
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
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

    function testNativeETHWithdrawForcedRecipient() public {
        bytes memory wp = abi.encode(WithdrawParams({ authorizedCaller: admin, forcedRecipient: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithWithdrawLeaf(wp);

        vm.deal(clone, 1 ether);

        uint256 userBalBefore = user.balance;

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(NATIVE_ASSET, user, 1 ether),
            proof
        );

        assertEq(user.balance - userBalBefore, 1 ether);
    }

    // --- Multi-leaf withdraw tree ---

    function testMultipleWithdrawLeaves() public {
        bytes memory userWp = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));
        bytes memory adminWp = abi.encode(WithdrawParams({ authorizedCaller: admin, forcedRecipient: address(0) }));
        bytes memory adminToUserWp = abi.encode(WithdrawParams({ authorizedCaller: admin, forcedRecipient: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(withdrawImpl), userWp);
        leaves[1] = _computeLeaf(address(withdrawImpl), adminWp);
        leaves[2] = _computeLeaf(address(withdrawImpl), adminToUserWp);
        leaves[3] = keccak256("padding");

        bytes32 root = merkle.getRoot(leaves);
        address clone = factory.deploy(address(dispatcher), root, keccak256("multi-withdraw"));

        token.mint(clone, 300e6);

        // User withdraws 100
        bytes32[] memory proof0 = merkle.getProof(leaves, 0);
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            userWp,
            abi.encode(address(token), user, 100e6),
            proof0
        );

        // Admin withdraws 100 to themselves
        bytes32[] memory proof1 = merkle.getProof(leaves, 1);
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            adminWp,
            abi.encode(address(token), admin, 100e6),
            proof1
        );

        // Admin withdraws 100 to user (forced)
        bytes32[] memory proof2 = merkle.getProof(leaves, 2);
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            adminToUserWp,
            abi.encode(address(token), user, 100e6),
            proof2
        );

        assertEq(token.balanceOf(user), 200e6);
        assertEq(token.balanceOf(admin), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }
}
