// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { RoutePolicyImmutableRoot } from "../../../../contracts/periphery/counterfactual/RoutePolicyImmutableRoot.sol";
import { deployRoutePolicy, rotateRoot } from "../utils/RoutePolicyTestHelper.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract AdminWithdrawManagerTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    WithdrawImplementation public withdrawImpl;
    AdminWithdrawManager public manager;
    RoutePolicyImmutableRoot public policy;
    MintableERC20 public token;

    address public owner;
    address public directWithdrawer;
    address public user;
    uint256 public signerPrivateKey;
    address public signerAddr;

    address public depositAddress;
    bytes32[] public withdrawProof;

    bytes32 constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256(
            "SignedWithdraw(address depositAddress,address withdrawImpl,address token,uint256 amount,uint256 deadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant MANAGER_NAME_HASH = keccak256("AdminWithdrawManager");
    bytes32 constant MANAGER_VERSION_HASH = keccak256("v2.0.0");

    function setUp() public {
        owner = makeAddr("owner");
        directWithdrawer = makeAddr("directWithdrawer");
        user = makeAddr("user");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);

        token = new MintableERC20("USDC", "USDC", 6);
        // Manager has no impl dependency, so it deploys first; the impl then references its address.
        manager = new AdminWithdrawManager(owner, directWithdrawer, signerAddr);
        withdrawImpl = new WithdrawImplementation(address(manager));
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        policy = deployRoutePolicy(address(this), bytes32(0));

        depositAddress = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("test-salt"));
        token.mint(depositAddress, 100e6);

        // Activate a policy tree containing the withdraw leaf so manager-driven flows can prove it.
        withdrawProof = _activateWithdrawLeaf();
    }

    /// @dev Activates a two-leaf policy tree where leaf 0 is `(withdrawImpl, "")` and leaf 1 is
    ///      padding. Returns the proof for the withdraw leaf.
    function _activateWithdrawLeaf() internal returns (bytes32[] memory proof) {
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(address(withdrawImpl), keccak256("")))));
        bytes32 padding = keccak256("padding");
        bytes32 root = leaf < padding
            ? keccak256(abi.encodePacked(leaf, padding))
            : keccak256(abi.encodePacked(padding, leaf));
        proof = new bytes32[](1);
        proof[0] = padding;
        rotateRoot(policy, address(this), root);
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

    function _managerDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    MANAGER_NAME_HASH,
                    MANAGER_VERSION_HASH,
                    block.chainid,
                    address(manager)
                )
            );
    }

    function _signWithdraw(
        address _depositAddress,
        address _withdrawImpl,
        address _token,
        uint256 _amount,
        uint256 _deadline,
        uint256 _privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, _depositAddress, _withdrawImpl, _token, _amount, _deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _managerDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- directWithdraw ---

    function testDirectWithdrawSendsToUserAddress() public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(manager), address(token), user, 50e6);

        vm.prank(directWithdrawer);
        manager.directWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            50e6,
            user,
            withdrawProof
        );

        assertEq(token.balanceOf(user), 50e6);
    }

    function testDirectWithdrawToArbitraryAddress() public {
        address treasury = makeAddr("treasury");

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(manager), address(token), treasury, 50e6);

        vm.prank(directWithdrawer);
        manager.directWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            50e6,
            treasury,
            withdrawProof
        );

        assertEq(token.balanceOf(treasury), 50e6);
        assertEq(token.balanceOf(user), 0);
    }

    function testDirectWithdrawUnauthorized() public {
        vm.expectRevert(AdminWithdrawManager.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        manager.directWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            50e6,
            user,
            withdrawProof
        );
    }

    // --- signedWithdraw ---

    function testSignedWithdrawSendsToUserAddress() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(
            depositAddress,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            signerPrivateKey
        );

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(manager), address(token), user, amount);

        // Anyone can submit the tx; recipient is always the clone's userAddress.
        vm.prank(makeAddr("submitter"));
        manager.signedWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            sig,
            withdrawProof
        );

        assertEq(token.balanceOf(user), amount);
    }

    function testSignedWithdrawInvalidSignature() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        uint256 wrongKey = 0xDEAD;
        bytes memory badSig = _signWithdraw(
            depositAddress,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            wrongKey
        );

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            badSig,
            withdrawProof
        );
    }

    function testSignedWithdrawExpired() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signWithdraw(
            depositAddress,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            signerPrivateKey
        );

        vm.warp(block.timestamp + 101);

        vm.expectRevert(AdminWithdrawManager.SignatureExpired.selector);
        manager.signedWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            sig,
            withdrawProof
        );
    }

    function testSignerCannotRedirectFunds() public {
        // A signed withdraw lands at cloneArgs.userAddress regardless of who submits. A compromised
        // signer cannot author a signature that redirects funds.
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(
            depositAddress,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            signerPrivateKey
        );

        address attackerControlled = makeAddr("attacker-controlled");
        vm.prank(attackerControlled);
        manager.signedWithdraw(
            depositAddress,
            _cloneArgs(),
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            sig,
            withdrawProof
        );

        assertEq(token.balanceOf(user), amount);
        assertEq(token.balanceOf(attackerControlled), 0);
    }

    // --- Owner functions ---

    function testSetDirectWithdrawer() public {
        address newWithdrawer = makeAddr("newWithdrawer");

        vm.expectEmit(true, false, false, false);
        emit AdminWithdrawManager.DirectWithdrawerUpdated(newWithdrawer);

        vm.prank(owner);
        manager.setDirectWithdrawer(newWithdrawer);

        assertEq(manager.directWithdrawer(), newWithdrawer);
    }

    function testSetSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, false, false, false);
        emit AdminWithdrawManager.SignerUpdated(newSigner);

        vm.prank(owner);
        manager.setSigner(newSigner);

        assertEq(manager.signer(), newSigner);
    }

    function testSetDirectWithdrawerUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        manager.setDirectWithdrawer(makeAddr("newWithdrawer"));
    }

    function testSetSignerUnauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        manager.setSigner(makeAddr("newSigner"));
    }

    // --- Cross-clone replay: signature includes depositAddress ---

    function testSignatureBoundToDepositAddress() public {
        // Deploy a second clone with the same userAddress but different recipient field
        // → different argsHash → different clone address.
        CloneArgs memory args2 = _cloneArgs();
        args2.recipient = bytes32(uint256(uint160(makeAddr("other-recipient"))));
        address depositAddress2 = factory.deploy(address(dispatcher), args2, keccak256("salt-2"));
        token.mint(depositAddress2, 100e6);

        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        // Signature was issued for depositAddress (clone 1).
        bytes memory sig = _signWithdraw(
            depositAddress,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            signerPrivateKey
        );

        // Replay against depositAddress2 fails — the signature commits to depositAddress.
        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdraw(
            depositAddress2,
            args2,
            address(withdrawImpl),
            address(token),
            amount,
            deadline,
            sig,
            withdrawProof
        );
    }
}
