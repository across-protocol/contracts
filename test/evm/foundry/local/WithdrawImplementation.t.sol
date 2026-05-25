// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { deployRoutePolicy } from "../utils/RoutePolicyTestHelper.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Tests for WithdrawImplementation. The dispatcher's admin escape (msg.sender ==
 *         cloneArgs.admin) provides the auth — this file only exercises the impl's transfer
 *         semantics (ERC-20 and native ETH).
 */
contract WithdrawImplementationTest is Test {
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositFactory public factory;
    WithdrawImplementation public withdrawImpl;
    RoutePolicyImmutableRoot public policy;
    MintableERC20 public token;

    address public admin;
    address public relayer;

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        policy = deployRoutePolicy(address(this), bytes32(0));
        token = new MintableERC20("USDC", "USDC", 6);

        admin = makeAddr("admin");
        relayer = makeAddr("relayer");
    }

    function _cloneArgs() internal returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(token)))),
                destinationChainId: 42161,
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                admin: admin,
                routePolicyAddress: address(policy)
            });
    }

    function _deployClone() internal returns (address) {
        return factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));
    }

    // --- ERC-20 withdraw ---

    function testERC20Withdraw() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);

        address to = makeAddr("recipient-of-funds");

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(admin, address(token), to, 100e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), to, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(token.balanceOf(to), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    function testPartialWithdraw() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), admin, uint256(30e6)),
            new bytes32[](0)
        );
        assertEq(token.balanceOf(admin), 30e6);
        assertEq(token.balanceOf(clone), 70e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), admin, uint256(70e6)),
            new bytes32[](0)
        );
        assertEq(token.balanceOf(admin), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    // --- Native ETH withdraw ---

    function testNativeETHWithdraw() public {
        address clone = _deployClone();
        vm.deal(clone, 1 ether);

        uint256 balBefore = admin.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(admin, NATIVE_ASSET, admin, 1 ether);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(NATIVE_ASSET, admin, uint256(1 ether)),
            new bytes32[](0)
        );

        assertEq(admin.balance - balBefore, 1 ether);
        assertEq(clone.balance, 0);
    }

    function testNativeETHWithdrawFailsOnRevertingReceiver() public {
        address clone = _deployClone();
        vm.deal(clone, 1 ether);

        // Deploy a contract with no receive() so the native transfer reverts.
        RejectsETH receiver = new RejectsETH();

        vm.expectRevert(WithdrawImplementation.NativeTransferFailed.selector);
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(NATIVE_ASSET, address(receiver), uint256(1 ether)),
            new bytes32[](0)
        );
    }

    // --- Caller is recorded in the event ---

    function testCallerIsRecordedInEvent() public {
        address clone = _deployClone();
        token.mint(clone, 50e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(admin, address(token), admin, 50e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), admin, uint256(50e6)),
            new bytes32[](0)
        );
    }
}

contract RejectsETH {
    // Intentionally no receive() / fallback; native transfers revert.
}
