// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { deployRoutePolicy, rotateRoot } from "../utils/RoutePolicyTestHelper.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Tests for WithdrawImplementation. Two authorized callers — the impl's immutable `admin`
 *         (typically an AdminWithdrawManager) and the clone's `userAddress` — can trigger
 *         withdrawals; recipients are always forced to `userAddress`.
 */
contract WithdrawImplementationTest is Test {
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositFactory public factory;
    WithdrawImplementation public withdrawImpl;
    RoutePolicyImmutableRoot public policy;
    MintableERC20 public token;

    address public withdrawAdmin;
    address public user;
    address public relayer;
    address public policyOwner;

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        withdrawAdmin = makeAddr("withdrawAdmin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        policyOwner = makeAddr("policyOwner");

        withdrawImpl = new WithdrawImplementation(withdrawAdmin);
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        policy = deployRoutePolicy(policyOwner, bytes32(0));
        token = new MintableERC20("USDC", "USDC", 6);
    }

    function _cloneArgs() internal returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(token)))),
                destinationChainId: 42161,
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                userAddress: user,
                routePolicyAddress: address(policy)
            });
    }

    function _deployClone() internal returns (address) {
        return factory.deploy(address(dispatcher), _cloneArgs(), keccak256("salt"));
    }

    /// @dev Build a single-leaf policy tree containing a `(withdrawImpl, "")` leaf and activate it.
    function _activateWithdrawLeaf() internal returns (bytes32[] memory proof) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(withdrawImpl), keccak256("")))));
        bytes32 padding = keccak256("padding");
        bytes32 root = leaf < padding
            ? keccak256(abi.encodePacked(leaf, padding))
            : keccak256(abi.encodePacked(padding, leaf));
        proof = new bytes32[](1);
        proof[0] = padding;
        rotateRoot(policy, policyOwner, root);
    }

    // --- User can withdraw (no policy required) ---

    function testUserCanWithdrawERC20() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(user, address(token), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    function testUserCanWithdrawNativeETH() public {
        address clone = _deployClone();
        vm.deal(clone, 1 ether);
        uint256 balBefore = user.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(user, NATIVE_ASSET, user, 1 ether);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(NATIVE_ASSET, uint256(1 ether)),
            new bytes32[](0)
        );

        assertEq(user.balance - balBefore, 1 ether);
        assertEq(clone.balance, 0);
    }

    function testPartialWithdraw() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(30e6)),
            new bytes32[](0)
        );
        assertEq(token.balanceOf(user), 30e6);
        assertEq(token.balanceOf(clone), 70e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(70e6)),
            new bytes32[](0)
        );
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(clone), 0);
    }

    // --- Immutable admin can withdraw via the merkle path ---

    function testAdminCanWithdrawViaMerklePath() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);
        bytes32[] memory proof = _activateWithdrawLeaf();

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(withdrawAdmin, address(token), user, 100e6);

        vm.prank(withdrawAdmin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(100e6)),
            proof
        );

        // Funds always go to userAddress, never to the caller.
        assertEq(token.balanceOf(user), 100e6);
        assertEq(token.balanceOf(withdrawAdmin), 0);
        assertEq(token.balanceOf(clone), 0);
    }

    // --- Random callers are rejected ---

    function testRandomCallerRevertsAtImplWithValidProof() public {
        // Defense-in-depth: even with a valid proof, callers other than {admin, userAddress} are
        // rejected by the impl's own auth check.
        address clone = _deployClone();
        token.mint(clone, 100e6);
        bytes32[] memory proof = _activateWithdrawLeaf();

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(100e6)),
            proof
        );
    }

    function testRandomCallerWithoutProofRevertsAtDispatcher() public {
        address clone = _deployClone();
        token.mint(clone, 100e6);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(100e6)),
            new bytes32[](0)
        );
    }

    // --- Native ETH transfer failure ---

    function testNativeETHRevertsIfUserAddressRejects() public {
        // Set up a clone whose userAddress is a contract that rejects ETH. Native transfer to it fails.
        RejectsETH rejecter = new RejectsETH();

        CloneArgs memory args = _cloneArgs();
        args.userAddress = address(rejecter);
        address clone = factory.deploy(address(dispatcher), args, keccak256("rejecter-clone"));
        vm.deal(clone, 1 ether);

        vm.expectRevert(WithdrawImplementation.NativeTransferFailed.selector);
        vm.prank(address(rejecter));
        ICounterfactualDeposit(clone).execute(
            args,
            address(withdrawImpl),
            "",
            abi.encode(NATIVE_ASSET, uint256(1 ether)),
            new bytes32[](0)
        );
    }

    // --- Event carries caller + forced recipient ---

    function testCallerRecordedInEvent() public {
        address clone = _deployClone();
        token.mint(clone, 50e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(user, address(token), user, 50e6);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), uint256(50e6)),
            new bytes32[](0)
        );
    }
}

contract RejectsETH {
    // Intentionally no receive() / fallback; native transfers revert.
}
