// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract AdminWithdrawManagerTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    WithdrawImplementation public withdrawImpl;
    AdminWithdrawManager public manager;
    RoutePolicy public policy;
    MintableERC20 public token;

    address public owner;
    address public directWithdrawer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    address public depositAddress;

    bytes32 constant SIGNED_WITHDRAW_TYPEHASH =
        keccak256("SignedWithdraw(address depositAddress,address token,address to,uint256 amount,uint256 deadline)");
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant MANAGER_NAME_HASH = keccak256("AdminWithdrawManager");
    bytes32 constant MANAGER_VERSION_HASH = keccak256("v1.1.0");

    function setUp() public {
        owner = makeAddr("owner");
        directWithdrawer = makeAddr("directWithdrawer");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);

        token = new MintableERC20("USDC", "USDC", 6);
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit(address(withdrawImpl));
        factory = new CounterfactualDepositFactory();
        policy = new RoutePolicy(address(this), bytes32(0));
        manager = new AdminWithdrawManager(owner, directWithdrawer, signerAddr, address(withdrawImpl));

        // Deploy a clone with withdrawUser = manager so the structural escape lands on the manager.
        depositAddress = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("test-salt"));
        token.mint(depositAddress, 100e6);
    }

    function _cloneArgs() internal returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(token)))),
                destinationChainId: 42161,
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                withdrawUser: address(manager),
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
        address _token,
        address _to,
        uint256 _amount,
        uint256 _deadline,
        uint256 _privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, _depositAddress, _token, _to, _amount, _deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _managerDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- directWithdraw ---

    function testDirectWithdraw() public {
        address recipient = makeAddr("recipient-of-funds");

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(manager), address(token), recipient, 50e6);

        vm.prank(directWithdrawer);
        manager.directWithdraw(depositAddress, _cloneArgs(), address(token), recipient, 50e6);

        assertEq(token.balanceOf(recipient), 50e6);
    }

    function testDirectWithdrawUnauthorized() public {
        vm.expectRevert(AdminWithdrawManager.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        manager.directWithdraw(depositAddress, _cloneArgs(), address(token), makeAddr("attacker"), 50e6);
    }

    function testDirectWithdrawCallerCanChooseRecipient() public {
        address attackerControlled = makeAddr("attacker-controlled");

        // The directWithdrawer is fully trusted — it can withdraw to any address it wants.
        vm.prank(directWithdrawer);
        manager.directWithdraw(depositAddress, _cloneArgs(), address(token), attackerControlled, 50e6);

        assertEq(token.balanceOf(attackerControlled), 50e6);
    }

    // --- signedWithdraw ---

    function testSignedWithdraw() public {
        address to = makeAddr("signer-chose-recipient");
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), to, amount, deadline, signerPrivateKey);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(manager), address(token), to, amount);

        // Anyone can submit the tx; the signer authorized `to`.
        vm.prank(makeAddr("submitter"));
        manager.signedWithdraw(depositAddress, _cloneArgs(), address(token), to, amount, deadline, sig);

        assertEq(token.balanceOf(to), amount);
    }

    function testSignedWithdrawInvalidSignature() public {
        address to = makeAddr("recipient");
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        uint256 wrongKey = 0xDEAD;
        bytes memory badSig = _signWithdraw(depositAddress, address(token), to, amount, deadline, wrongKey);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdraw(depositAddress, _cloneArgs(), address(token), to, amount, deadline, badSig);
    }

    function testSignedWithdrawExpired() public {
        address to = makeAddr("recipient");
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signWithdraw(depositAddress, address(token), to, amount, deadline, signerPrivateKey);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(AdminWithdrawManager.SignatureExpired.selector);
        manager.signedWithdraw(depositAddress, _cloneArgs(), address(token), to, amount, deadline, sig);
    }

    function testSignedWithdrawMismatchedRecipientReverts() public {
        address signedTo = makeAddr("signed-to");
        address attackerTo = makeAddr("attacker-to");
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        // Signer signs for `signedTo` but caller tries to use `attackerTo` — recovered signer mismatches.
        bytes memory sig = _signWithdraw(depositAddress, address(token), signedTo, amount, deadline, signerPrivateKey);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdraw(depositAddress, _cloneArgs(), address(token), attackerTo, amount, deadline, sig);
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
        // Deploy a second clone with the same withdrawUser (manager) but different recipient field
        // → different argsHash → different clone address.
        CloneArgs memory args2 = _cloneArgs();
        args2.recipient = bytes32(uint256(uint160(makeAddr("other-recipient"))));
        address depositAddress2 = factory.deploy(address(dispatcher), args2, keccak256("salt-2"));
        token.mint(depositAddress2, 100e6);

        address to = makeAddr("recipient");
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        // Signature was issued for depositAddress (clone 1).
        bytes memory sig = _signWithdraw(depositAddress, address(token), to, amount, deadline, signerPrivateKey);

        // Replay against depositAddress2 fails — the signature commits to depositAddress.
        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdraw(depositAddress2, args2, address(token), to, amount, deadline, sig);
    }
}
