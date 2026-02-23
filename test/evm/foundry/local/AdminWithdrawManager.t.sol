// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { WithdrawImplementation, WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract AdminWithdrawManagerTest is Test {
    Merkle public merkle;
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    WithdrawImplementation public withdrawImpl;
    AdminWithdrawManager public manager;
    MintableERC20 public token;

    address public owner;
    address public directWithdrawer;
    address public user;
    uint256 public signerPrivateKey;
    address public signerAddr;

    address public depositAddress;

    // Withdraw params for the merkle leaves
    bytes internal directWithdrawParams; // manager as caller, any recipient
    bytes internal signedWithdrawParams; // manager as caller, forced to user
    bytes internal userWithdrawParams; // user as caller, any recipient

    // Proofs
    bytes32[] internal directProof;
    bytes32[] internal signedProof;
    bytes32[] internal userProof;

    // EIP-712 constants for AdminWithdrawManager
    bytes32 constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256("SignedWithdraw(address depositAddress,address token,uint256 amount,uint256 deadline)");
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant MANAGER_NAME_HASH = keccak256("AdminWithdrawManager");
    bytes32 constant MANAGER_VERSION_HASH = keccak256("v1.0.0");

    function setUp() public {
        owner = makeAddr("owner");
        directWithdrawer = makeAddr("directWithdrawer");
        user = makeAddr("user");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);

        merkle = new Merkle();
        token = new MintableERC20("USDC", "USDC", 6);
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        withdrawImpl = new WithdrawImplementation();
        manager = new AdminWithdrawManager(owner, directWithdrawer, signerAddr);

        // Build merkle tree with three withdraw leaves
        directWithdrawParams = abi.encode(
            WithdrawParams({ authorizedCaller: address(manager), forcedRecipient: address(0) })
        );
        signedWithdrawParams = abi.encode(
            WithdrawParams({ authorizedCaller: address(manager), forcedRecipient: user })
        );
        userWithdrawParams = abi.encode(WithdrawParams({ authorizedCaller: user, forcedRecipient: address(0) }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(withdrawImpl), directWithdrawParams);
        leaves[1] = _computeLeaf(address(withdrawImpl), signedWithdrawParams);
        leaves[2] = _computeLeaf(address(withdrawImpl), userWithdrawParams);
        leaves[3] = keccak256("padding");

        bytes32 root = merkle.getRoot(leaves);
        directProof = merkle.getProof(leaves, 0);
        signedProof = merkle.getProof(leaves, 1);
        userProof = merkle.getProof(leaves, 2);

        depositAddress = factory.deploy(address(dispatcher), root, keccak256("test-salt"));

        // Fund the clone
        token.mint(depositAddress, 100e6);
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(implementation, keccak256(params)));
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
        address _token,
        uint256 _amount,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, _depositAddress, _token, _amount, _deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _managerDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- directWithdraw tests ---

    function testDirectWithdraw() public {
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), recipient, 50e6);

        vm.prank(directWithdrawer);
        manager.directWithdraw(
            depositAddress,
            address(withdrawImpl),
            directWithdrawParams,
            abi.encode(address(token), recipient, 50e6),
            directProof
        );

        assertEq(token.balanceOf(recipient), 50e6);
    }

    function testDirectWithdrawUnauthorized() public {
        vm.expectRevert(AdminWithdrawManager.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        manager.directWithdraw(
            depositAddress,
            address(withdrawImpl),
            directWithdrawParams,
            abi.encode(address(token), user, 50e6),
            directProof
        );
    }

    // --- signedWithdrawToUser tests ---

    function testSignedWithdrawToUser() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, deadline);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, amount);

        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            signedWithdrawParams,
            address(token),
            user,
            amount,
            signedProof,
            deadline,
            sig
        );

        assertEq(token.balanceOf(user), amount);
    }

    function testSignedWithdrawToUserInvalidSignature() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        // Sign with wrong key
        uint256 wrongKey = 0xDEAD;
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, address(token), amount, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _managerDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            signedWithdrawParams,
            address(token),
            user,
            amount,
            signedProof,
            deadline,
            badSig
        );
    }

    function testSignedWithdrawToUserExpired() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, deadline);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(AdminWithdrawManager.SignatureExpired.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            signedWithdrawParams,
            address(token),
            user,
            amount,
            signedProof,
            deadline,
            sig
        );
    }

    function testSignedWithdrawWrongRecipientReverts() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, deadline);

        // Try sending to admin instead of forced user
        vm.expectRevert(WithdrawImplementation.InvalidRecipient.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            signedWithdrawParams,
            address(token),
            makeAddr("notUser"), // wrong recipient, forcedRecipient is user
            amount,
            signedProof,
            deadline,
            sig
        );
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

    // --- User withdraw via dispatcher (not AdminWithdrawManager) ---

    function testUserWithdrawDirect() public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, 50e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            userWithdrawParams,
            abi.encode(address(token), user, 50e6),
            userProof
        );

        assertEq(token.balanceOf(user), 50e6);
    }
}
