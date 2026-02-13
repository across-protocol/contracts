// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositExecutor } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositExecutor.sol";
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
    CounterfactualDepositExecutor public executor;
    MockSponsoredCCTPSrcPeriphery public srcPeriphery;
    MintableERC20 public burnToken;

    address public admin;
    address public user;
    address public relayer;

    uint32 public constant SOURCE_DOMAIN = 0; // Ethereum
    uint32 public constant DESTINATION_DOMAIN = 3; // Hyperliquid
    bytes32 public finalRecipient;
    bytes32 public userWithdrawAddr;

    // Default route params used across tests
    ICounterfactualDepositFactory.CounterfactualImmutables internal defaultParams;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));
        userWithdrawAddr = bytes32(uint256(uint160(user)));

        burnToken = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredCCTPSrcPeriphery();
        factory = new CounterfactualDepositFactory();
        executor = new CounterfactualDepositExecutor(address(srcPeriphery), SOURCE_DOMAIN);

        burnToken.mint(user, 1000e6);

        defaultParams = ICounterfactualDepositFactory.CounterfactualImmutables({
            destinationDomain: DESTINATION_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(makeAddr("dstPeriphery")))),
            burnToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationCaller: bytes32(uint256(uint160(makeAddr("bot")))),
            maxFeeBps: 100, // 1%
            minFinalityThreshold: 1000,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 50,
            finalRecipient: finalRecipient,
            finalToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            userWithdrawAddress: userWithdrawAddr,
            adminWithdrawAddress: bytes32(uint256(uint160(admin))),
            actionData: ""
        });
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(executor), defaultParams, salt);
        address deployed = factory.deploy(address(executor), defaultParams, salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployEmitsEvent() public {
        bytes32 salt = keccak256("test-salt");

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositAddressCreated(
            factory.predictDepositAddress(address(executor), defaultParams, salt),
            defaultParams.burnToken,
            defaultParams.destinationDomain,
            defaultParams.finalRecipient,
            salt
        );

        factory.deploy(address(executor), defaultParams, salt);
    }

    function testCannotDeployTwice() public {
        bytes32 salt = keccak256("test-salt");

        factory.deploy(address(executor), defaultParams, salt);

        vm.expectRevert();
        factory.deploy(address(executor), defaultParams, salt);
    }

    function testDeployedContractStoresCorrectHash() public {
        bytes32 salt = keccak256("test-salt");

        address deployed = factory.deploy(address(executor), defaultParams, salt);

        bytes memory args = Clones.fetchCloneArgs(deployed);
        bytes32 storedHash = abi.decode(args, (bytes32));
        bytes32 expectedHash = keccak256(abi.encode(defaultParams));

        assertEq(storedHash, expectedHash, "Stored hash should match keccak256 of params");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;

        address depositAddress = factory.predictDepositAddress(address(executor), defaultParams, salt);

        // User sends tokens to deposit address
        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        // Execute
        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositExecuted(depositAddress, amount, nonce);

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(
            address(executor),
            defaultParams,
            salt,
            amount,
            nonce,
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(srcPeriphery.lastAmount(), amount, "SrcPeriphery should have received correct amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testMaxFeeBpsCalculation() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        vm.prank(relayer);
        factory.executeOnExisting(depositAddress, defaultParams, amount, nonce, block.timestamp + 1 hours, "sig");

        // maxFeeBps = 100 (1%), amount = 100e6
        // Expected maxFee = 100e6 * 100 / 10000 = 1e6
        assertEq(srcPeriphery.lastMaxFee(), 1e6, "maxFee should be 1% of amount");
    }

    function testExecuteOnExisting() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // First deposit
        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        factory.executeOnExisting(
            depositAddress,
            defaultParams,
            100e6,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        // Second deposit (reuse same clone)
        vm.prank(user);
        burnToken.transfer(depositAddress, 50e6);

        vm.prank(relayer);
        factory.executeOnExisting(
            depositAddress,
            defaultParams,
            50e6,
            keccak256("nonce-2"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(burnToken.balanceOf(depositAddress), 0, "All tokens should be deposited");
    }

    function testExecuteWithInsufficientBalance() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // Send insufficient tokens
        vm.prank(user);
        burnToken.transfer(depositAddress, 50e6);

        // Try to deposit more than balance
        vm.expectRevert(ICounterfactualDepositFactory.InsufficientBalance.selector);
        vm.prank(relayer);
        factory.executeOnExisting(
            depositAddress,
            defaultParams,
            100e6,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // Send wrong token
        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        // Admin withdraws — must pass params for hash verification
        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.AdminWithdraw(depositAddress, address(wrongToken), admin, 100e18);

        vm.prank(admin);
        CounterfactualDepositExecutor(depositAddress).adminWithdraw(defaultParams, address(wrongToken), admin, 100e18);

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
        assertEq(wrongToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        vm.expectRevert(ICounterfactualDepositFactory.Unauthorized.selector);
        vm.prank(user);
        CounterfactualDepositExecutor(depositAddress).adminWithdraw(defaultParams, address(burnToken), user, 100e6);
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // Send tokens to deposit address
        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        // userWithdrawAddress (user) withdraws tokens — must pass params for hash verification
        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.UserWithdraw(depositAddress, address(burnToken), user, 100e6);

        vm.prank(user);
        CounterfactualDepositExecutor(depositAddress).userWithdraw(defaultParams, address(burnToken), user, 100e6);

        assertEq(burnToken.balanceOf(user), 1000e6, "User should have all tokens back");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        vm.expectRevert(ICounterfactualDepositFactory.Unauthorized.selector);
        vm.prank(relayer);
        CounterfactualDepositExecutor(depositAddress).userWithdraw(defaultParams, address(burnToken), relayer, 100e6);
    }

    function testDeployAndExecuteWhenAlreadyDeployed() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;

        // Deploy first
        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // Fund the deposit address
        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        // Call deployAndExecute on already-deployed clone (exercises catch branch)
        vm.prank(relayer);
        address returned = factory.deployAndExecute(
            address(executor),
            defaultParams,
            salt,
            amount,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(returned, depositAddress, "Should return correct address from catch branch");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit should have executed");
        assertEq(srcPeriphery.callCount(), 1, "SrcPeriphery should have been called once");
    }

    function testExecuteOnImplementationReverts() public {
        // Calling executeDeposit directly on the executor implementation (not a clone)
        // should revert because fetchCloneArgs will fail on non-clone bytecode
        vm.expectRevert();
        executor.executeDeposit(defaultParams, 100e6, keccak256("nonce"), block.timestamp + 1 hours, "sig");
    }

    function testInvalidParamsHash() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(executor), defaultParams, salt);

        // Create wrong params (different maxFeeBps)
        ICounterfactualDepositFactory.CounterfactualImmutables memory wrongParams = defaultParams;
        wrongParams.maxFeeBps = 200;

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        // executeDeposit with wrong params should revert
        vm.expectRevert(ICounterfactualDepositFactory.InvalidParamsHash.selector);
        vm.prank(relayer);
        factory.executeOnExisting(
            depositAddress,
            wrongParams,
            100e6,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        // userWithdraw with wrong params should also revert
        vm.expectRevert(ICounterfactualDepositFactory.InvalidParamsHash.selector);
        vm.prank(user);
        CounterfactualDepositExecutor(depositAddress).userWithdraw(wrongParams, address(burnToken), user, 100e6);
    }

    function testDeployWithActionData() public {
        bytes32 salt = keccak256("test-salt-action");
        bytes memory actionData = abi.encode(uint256(42), address(0xBEEF));

        ICounterfactualDepositFactory.CounterfactualImmutables memory params = defaultParams;
        params.actionData = actionData;

        address depositAddress = factory.deploy(address(executor), params, salt);

        // Verify clone stores the correct hash
        bytes memory args = Clones.fetchCloneArgs(depositAddress);
        bytes32 storedHash = abi.decode(args, (bytes32));
        assertEq(storedHash, keccak256(abi.encode(params)), "Stored hash should match params with actionData");

        // Fund and execute deposit
        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        factory.executeOnExisting(
            depositAddress,
            params,
            100e6,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(srcPeriphery.callCount(), 1, "Deposit should be executed");
    }
}
