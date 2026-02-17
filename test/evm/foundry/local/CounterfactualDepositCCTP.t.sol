// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositCCTP, CCTPImmutables } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualDepositFactory } from "../../../../contracts/interfaces/ICounterfactualDepositFactory.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SponsoredCCTPSrcPeriphery that simulates the token transfer without CCTP
 */
contract MockSponsoredCCTPSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMaxFee;
    uint256 public callCount;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        address burnToken = address(uint160(uint256(quote.burnToken)));
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        lastMaxFee = quote.maxFee;
        callCount++;
    }
}

contract CounterfactualDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositCCTP public implementation;
    MockSponsoredCCTPSrcPeriphery public srcPeriphery;
    MintableERC20 public burnToken;

    address public admin;
    address public user;
    address public relayer;

    uint32 public constant SOURCE_DOMAIN = 0; // Ethereum
    uint32 public constant DESTINATION_DOMAIN = 3; // Hyperliquid
    bytes32 public finalRecipient;
    address public userWithdrawAddr;

    CCTPImmutables internal defaultParams;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));
        userWithdrawAddr = user;

        burnToken = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredCCTPSrcPeriphery();
        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositCCTP(address(srcPeriphery), SOURCE_DOMAIN);

        burnToken.mint(user, 1000e6);

        defaultParams = CCTPImmutables({
            destinationDomain: DESTINATION_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(makeAddr("dstPeriphery")))),
            burnToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationCaller: bytes32(uint256(uint160(makeAddr("bot")))),
            cctpMaxFeeBps: 100,
            executionFee: 1e6,
            minFinalityThreshold: 1000,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 50,
            finalRecipient: finalRecipient,
            finalToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            userWithdrawAddress: userWithdrawAddr,
            adminWithdrawAddress: admin,
            actionData: ""
        });
    }

    function _encodedParams() internal view returns (bytes memory) {
        return abi.encode(defaultParams);
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(implementation), _encodedParams(), salt);
        address deployed = factory.deploy(address(implementation), _encodedParams(), salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployEmitsEvent() public {
        bytes32 salt = keccak256("test-salt");
        bytes memory encoded = _encodedParams();
        bytes32 paramsHash = keccak256(encoded);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositAddressCreated(
            factory.predictDepositAddress(address(implementation), encoded, salt),
            address(implementation),
            paramsHash,
            salt
        );

        factory.deploy(address(implementation), encoded, salt);
    }

    function testCannotDeployTwice() public {
        bytes32 salt = keccak256("test-salt");

        factory.deploy(address(implementation), _encodedParams(), salt);

        vm.expectRevert();
        factory.deploy(address(implementation), _encodedParams(), salt);
    }

    function testDeployedContractStoresCorrectHash() public {
        bytes32 salt = keccak256("test-salt");

        address deployed = factory.deploy(address(implementation), _encodedParams(), salt);

        bytes memory args = Clones.fetchCloneArgs(deployed);
        bytes32 storedHash = abi.decode(args, (bytes32));
        bytes32 expectedHash = keccak256(_encodedParams());

        assertEq(storedHash, expectedHash, "Stored hash should match keccak256 of encoded params");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultParams.executionFee;

        bytes memory encoded = _encodedParams();
        address depositAddress = factory.predictDepositAddress(address(implementation), encoded, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.DepositExecuted(depositAddress, expectedDeposit, nonce);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositCCTP.executeDeposit,
            (defaultParams, amount, relayer, nonce, block.timestamp + 1 hours, "sig")
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(implementation), encoded, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(burnToken.balanceOf(relayer), defaultParams.executionFee, "Relayer should receive execution fee");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testCctpMaxFeeBpsCalculation() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 depositAmount = amount - defaultParams.executionFee;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            defaultParams,
            amount,
            relayer,
            nonce,
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.lastMaxFee(), (depositAmount * 100) / 10000, "maxFee should be 1% of net deposit amount");
    }

    function testExecuteOnExistingClone() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        // First deposit
        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            defaultParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        // Second deposit (reuse same clone)
        vm.prank(user);
        burnToken.transfer(depositAddress, 50e6);

        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            defaultParams,
            50e6,
            relayer,
            keccak256("nonce-2"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(burnToken.balanceOf(depositAddress), 0, "All tokens should be deposited");
        assertEq(
            burnToken.balanceOf(relayer),
            2 * defaultParams.executionFee,
            "Relayer should receive fees from both deposits"
        );
    }

    function testExecuteWithInsufficientBalance() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, 50e6);

        vm.expectRevert(ICounterfactualDeposit.InsufficientBalance.selector);
        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            defaultParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(depositAddress, address(wrongToken), admin, 100e18);

        vm.prank(admin);
        CounterfactualDepositCCTP(depositAddress).adminWithdraw(defaultParams, address(wrongToken), admin, 100e18);

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
        assertEq(wrongToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(user);
        CounterfactualDepositCCTP(depositAddress).adminWithdraw(defaultParams, address(burnToken), user, 100e6);
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(depositAddress, address(burnToken), user, 100e6);

        vm.prank(user);
        CounterfactualDepositCCTP(depositAddress).userWithdraw(defaultParams, address(burnToken), user, 100e6);

        assertEq(burnToken.balanceOf(user), 1000e6, "User should have all tokens back");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).userWithdraw(defaultParams, address(burnToken), relayer, 100e6);
    }

    function testDeployAndExecuteWhenAlreadyDeployed() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;

        bytes memory encoded = _encodedParams();
        address depositAddress = factory.deploy(address(implementation), encoded, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositCCTP.executeDeposit,
            (defaultParams, amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig")
        );

        vm.prank(relayer);
        address returned = factory.deployAndExecute(address(implementation), encoded, salt, executeCalldata);

        assertEq(returned, depositAddress, "Should return correct address from catch branch");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit should have executed");
        assertEq(srcPeriphery.callCount(), 1, "SrcPeriphery should have been called once");
    }

    function testExecuteOnImplementationReverts() public {
        vm.expectRevert();
        implementation.executeDeposit(
            defaultParams,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testInvalidParamsHash() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        CCTPImmutables memory wrongParams = defaultParams;
        wrongParams.cctpMaxFeeBps = 200;

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        // executeDeposit with wrong params should revert
        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            wrongParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        // userWithdraw with wrong params should also revert
        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(user);
        CounterfactualDepositCCTP(depositAddress).userWithdraw(wrongParams, address(burnToken), user, 100e6);
    }

    function testExecuteWithZeroExecutionFee() public {
        CCTPImmutables memory params = defaultParams;
        params.executionFee = 0;
        bytes memory encoded = abi.encode(params);
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(implementation), encoded, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            params,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(burnToken.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(srcPeriphery.lastAmount(), amount, "Full amount should be deposited");
    }

    function testDeployAndExecuteRevertBubble() public {
        bytes32 salt = keccak256("test-salt");
        bytes memory encoded = _encodedParams();

        address depositAddress = factory.predictDepositAddress(address(implementation), encoded, salt);

        // Don't fund the clone, so executeDeposit will revert with InsufficientBalance
        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositCCTP.executeDeposit,
            (defaultParams, 100e6, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig")
        );

        vm.expectRevert(ICounterfactualDeposit.InsufficientBalance.selector);
        vm.prank(relayer);
        factory.deployAndExecute(address(implementation), encoded, salt, executeCalldata);
    }

    function testInvalidParamsHashOnWithdraw() public {
        bytes32 salt = keccak256("test-salt");
        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        CCTPImmutables memory wrongParams = defaultParams;
        wrongParams.cctpMaxFeeBps = 200;

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(admin);
        CounterfactualDepositCCTP(depositAddress).adminWithdraw(wrongParams, address(burnToken), admin, 100e6);
    }

    function testDeployWithActionData() public {
        bytes32 salt = keccak256("test-salt-action");
        bytes memory actionData = abi.encode(uint256(42), address(0xBEEF));

        CCTPImmutables memory params = defaultParams;
        params.actionData = actionData;
        bytes memory encoded = abi.encode(params);

        address depositAddress = factory.deploy(address(implementation), encoded, salt);

        bytes memory args = Clones.fetchCloneArgs(depositAddress);
        bytes32 storedHash = abi.decode(args, (bytes32));
        assertEq(storedHash, keccak256(encoded), "Stored hash should match params with actionData");

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        CounterfactualDepositCCTP(depositAddress).executeDeposit(
            params,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(srcPeriphery.callCount(), 1, "Deposit should be executed");
    }
}
