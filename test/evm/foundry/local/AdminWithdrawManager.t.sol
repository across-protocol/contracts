// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { CounterfactualNonces } from "../../../../contracts/periphery/counterfactual/CounterfactualNonces.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract AdminWithdrawManagerTest is CounterfactualTestBase {
    AdminWithdrawManager public manager;
    MintableERC20 public token;

    address public managerOwner;
    address public directWithdrawer;
    address public depositAddress;

    // Single withdraw leaf: admin = manager, user = user
    bytes internal withdrawParams;
    bytes32[] internal withdrawProof;

    bytes32 constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256("SignedWithdraw(address depositAddress,address token,uint256 amount,bytes32 nonce,uint256 deadline)");
    bytes32 constant MANAGER_VERSION_HASH = keccak256("v1.0.0");
    bytes32 constant DEFAULT_NONCE = keccak256("nonce-1");

    function setUp() public {
        _setUpCore();
        _deployBeacon(_baseConfig());
        managerOwner = makeAddr("managerOwner");
        directWithdrawer = makeAddr("directWithdrawer");

        token = new MintableERC20("USDC", "USDC", 6);
        // Reuse the base off-chain `signer` as the manager's signer.
        manager = new AdminWithdrawManager(managerOwner, directWithdrawer, signer);

        withdrawParams = abi.encode(WithdrawParams({ admin: address(manager), user: user }));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(withdrawImpl), withdrawParams);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        withdrawProof = merkle.getProof(leaves, 0);

        depositAddress = factory.deploy(keccak256("test-salt"), root);
        token.mint(depositAddress, 100e6);
    }

    function _managerDomainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    keccak256("AdminWithdrawManager"),
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
        bytes32 _nonce,
        uint256 _deadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, _depositAddress, _token, _amount, _nonce, _deadline)
        );
        return _sign(signerPk, _managerDomainSeparator(), structHash);
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
            withdrawParams,
            abi.encode(address(token), recipient, 50e6),
            withdrawProof
        );

        assertEq(token.balanceOf(recipient), 50e6);
    }

    function testDirectWithdrawUnauthorized() public {
        vm.expectRevert(AdminWithdrawManager.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        manager.directWithdraw(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            abi.encode(address(token), user, 50e6),
            withdrawProof
        );
    }

    // --- signedWithdrawToUser tests ---

    function testSignedWithdrawToUser() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, DEFAULT_NONCE, deadline);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, amount);

        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            sig
        );

        assertEq(token.balanceOf(user), amount);
    }

    function testSignedWithdrawToUserInvalidSignature() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        // Sign with wrong key
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, address(token), amount, DEFAULT_NONCE, deadline)
        );
        bytes memory badSig = _sign(0xDEAD, _managerDomainSeparator(), structHash);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            badSig
        );
    }

    function testSignedWithdrawToUserExpired() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, DEFAULT_NONCE, deadline);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(AdminWithdrawManager.SignatureExpired.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            sig
        );
    }

    /// @dev The nonce is consumed in the manager's storage on execution, so re-funding the clone and
    ///      replaying the same signed withdrawal within the deadline must revert.
    function testSignedWithdrawToUserNonceReplayReverts() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, DEFAULT_NONCE, deadline);

        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            sig
        );

        // Re-fund the clone and replay the identical (still unexpired) signature.
        token.mint(depositAddress, amount);
        vm.expectRevert(CounterfactualNonces.InvalidNonce.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            sig
        );
    }

    /// @dev A fresh nonce (freshly signed) withdraws fine from a re-funded clone: only replays are blocked.
    function testSignedWithdrawToUserFreshNonceAllowsRepeat() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            DEFAULT_NONCE,
            deadline,
            _signWithdraw(depositAddress, address(token), amount, DEFAULT_NONCE, deadline)
        );

        token.mint(depositAddress, amount);
        bytes32 nonce2 = keccak256("nonce-2");
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            nonce2,
            deadline,
            _signWithdraw(depositAddress, address(token), amount, nonce2, deadline)
        );

        assertEq(token.balanceOf(user), 2 * amount);
    }

    /// @dev The nonce is signature-bound: submitting an unused nonce with a signature over a different
    ///      nonce must revert.
    function testSignedWithdrawToUserWrongNonceSignatureReverts() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, DEFAULT_NONCE, deadline);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdrawToUser(
            depositAddress,
            address(withdrawImpl),
            withdrawParams,
            address(token),
            amount,
            withdrawProof,
            keccak256("other-nonce"),
            deadline,
            sig
        );
    }

    // --- Owner functions ---

    function testSetDirectWithdrawer() public {
        address newWithdrawer = makeAddr("newWithdrawer");

        vm.expectEmit(true, false, false, false);
        emit AdminWithdrawManager.DirectWithdrawerUpdated(newWithdrawer);

        vm.prank(managerOwner);
        manager.setDirectWithdrawer(newWithdrawer);

        assertEq(manager.directWithdrawer(), newWithdrawer);
    }

    function testSetSigner() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, false, false, false);
        emit AdminWithdrawManager.SignerUpdated(newSigner);

        vm.prank(managerOwner);
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

    // --- User withdraw directly via the proxy (not AdminWithdrawManager) ---

    function testUserWithdrawDirect() public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, 50e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            withdrawParams,
            abi.encode(address(token), user, 50e6),
            withdrawProof
        );

        assertEq(token.balanceOf(user), 50e6);
    }
}
