// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositMultiBridge } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositMultiBridge.sol";
import { CounterfactualDepositGlobalConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositBase.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

contract AdminWithdrawManagerTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositMultiBridge public implementation;
    AdminWithdrawManager public manager;
    MintableERC20 public token;

    address public owner;
    address public directWithdrawer;
    address public user;
    uint256 public signerPrivateKey;
    address public signerAddr;

    CounterfactualDepositGlobalConfig internal config;
    address public depositAddress;

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

        token = new MintableERC20("USDC", "USDC", 6);

        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositMultiBridge(
            makeAddr("cctp"),
            0,
            makeAddr("oft"),
            30101,
            makeAddr("spoke"),
            makeAddr("spokeSigner"),
            makeAddr("weth")
        );
        manager = new AdminWithdrawManager(owner, directWithdrawer, signerAddr);

        config = CounterfactualDepositGlobalConfig({
            routesRoot: keccak256("root"),
            userWithdrawAddress: user,
            adminWithdrawAddress: address(manager)
        });

        bytes32 paramsHash = keccak256(abi.encode(config));
        bytes32 salt = keccak256("test-salt");
        depositAddress = factory.deploy(address(implementation), paramsHash, salt);

        token.mint(depositAddress, 100e6);
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

    function _paramsBytes() internal view returns (bytes memory) {
        return abi.encode(config);
    }

    function testDirectWithdraw() public {
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(token), recipient, 50e6);

        vm.prank(directWithdrawer);
        manager.directWithdraw(
            depositAddress,
            abi.encodeCall(ICounterfactualDeposit.adminWithdraw, (_paramsBytes(), address(token), recipient, 50e6))
        );

        assertEq(token.balanceOf(recipient), 50e6);
    }

    function testDirectWithdrawUnauthorized() public {
        vm.expectRevert(AdminWithdrawManager.Unauthorized.selector);
        vm.prank(makeAddr("random"));
        manager.directWithdraw(
            depositAddress,
            abi.encodeCall(ICounterfactualDeposit.adminWithdraw, (_paramsBytes(), address(token), user, 50e6))
        );
    }

    function testSignedWithdrawToUser() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, deadline);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(token), user, amount);

        manager.signedWithdrawToUser(depositAddress, _paramsBytes(), address(token), amount, deadline, sig);

        assertEq(token.balanceOf(user), amount);
    }

    function testSignedWithdrawToUserInvalidSignature() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 3600;

        uint256 wrongKey = 0xDEAD;
        bytes32 structHash = keccak256(
            abi.encode(SIGNED_WITHDRAW_TYPEHASH, depositAddress, address(token), amount, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _managerDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.expectRevert(AdminWithdrawManager.InvalidSignature.selector);
        manager.signedWithdrawToUser(depositAddress, _paramsBytes(), address(token), amount, deadline, badSig);
    }

    function testSignedWithdrawToUserExpired() public {
        uint256 amount = 50e6;
        uint256 deadline = block.timestamp + 100;
        bytes memory sig = _signWithdraw(depositAddress, address(token), amount, deadline);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(AdminWithdrawManager.SignatureExpired.selector);
        manager.signedWithdrawToUser(depositAddress, _paramsBytes(), address(token), amount, deadline, sig);
    }

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

    function testAdminWithdrawToUser() public {
        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(token), user, 50e6);

        vm.prank(address(manager));
        ICounterfactualDeposit(depositAddress).adminWithdrawToUser(_paramsBytes(), address(token), 50e6);

        assertEq(token.balanceOf(user), 50e6);
    }

    function testBytesAdminWithdraw() public {
        address recipient = makeAddr("recipient");

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(token), recipient, 50e6);

        vm.prank(address(manager));
        ICounterfactualDeposit(depositAddress).adminWithdraw(_paramsBytes(), address(token), recipient, 50e6);

        assertEq(token.balanceOf(recipient), 50e6);
    }
}
