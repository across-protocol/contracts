// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositSpokePool, SpokePoolImmutables } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SpokePool that records deposit parameters
 */
contract MockSpokePool {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    bytes32 public lastDepositor;
    bytes32 public lastRecipient;
    bytes32 public lastInputToken;
    bytes32 public lastOutputToken;
    uint256 public lastInputAmount;
    uint256 public lastOutputAmount;
    uint256 public lastDestinationChainId;
    bytes32 public lastExclusiveRelayer;
    uint32 public lastQuoteTimestamp;
    uint32 public lastFillDeadline;
    uint32 public lastExclusivityDeadline;
    bytes public lastMessage;

    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        bytes32 exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable {
        address tokenAddr = address(uint160(uint256(inputToken)));
        IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), inputAmount);

        lastDepositor = depositor;
        lastRecipient = recipient;
        lastInputToken = inputToken;
        lastOutputToken = outputToken;
        lastInputAmount = inputAmount;
        lastOutputAmount = outputAmount;
        lastDestinationChainId = destinationChainId;
        lastExclusiveRelayer = exclusiveRelayer;
        lastQuoteTimestamp = quoteTimestamp;
        lastFillDeadline = fillDeadline;
        lastExclusivityDeadline = exclusivityDeadline;
        lastMessage = message;
        callCount++;
    }
}

contract CounterfactualSpokePoolDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositSpokePool public implementation;
    MockSpokePool public spokePool;
    MintableERC20 public inputToken;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    bytes32 public userWithdrawAddr;

    SpokePoolImmutables internal defaultParams;

    // EIP-712 constants (must match contract)
    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256("ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,uint32 fillDeadline)");
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        userWithdrawAddr = bytes32(uint256(uint160(user)));

        inputToken = new MintableERC20("USDC", "USDC", 6);

        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositSpokePool(address(spokePool), signerAddr);

        inputToken.mint(user, 1000e6);

        defaultParams = SpokePoolImmutables({
            destinationChainId: 42161, // Arbitrum
            inputToken: bytes32(uint256(uint160(address(inputToken)))),
            outputToken: bytes32(uint256(uint160(address(inputToken)))), // Same token
            recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            exclusiveRelayer: bytes32(0),
            price: 1e18, // 1:1
            maxFeeBps: 600, // 6%
            executionFee: 1e6, // 1 USDC
            exclusivityDeadline: 0,
            userWithdrawAddress: userWithdrawAddr,
            adminWithdrawAddress: bytes32(uint256(uint160(admin))),
            message: ""
        });
    }

    function _encodedParams() internal view returns (bytes memory) {
        return abi.encode(defaultParams);
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signExecuteDeposit(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 fillDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(EXECUTE_DEPOSIT_TYPEHASH, inputAmount, outputAmount, fillDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(implementation), _encodedParams(), salt);
        address deployed = factory.deploy(address(implementation), _encodedParams(), salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee; // 99 USDC
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory encoded = _encodedParams();
        address depositAddress = factory.predictDepositAddress(address(implementation), encoded, salt);

        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.DepositExecuted(depositAddress, expectedDeposit, bytes32(0));

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (defaultParams, inputAmount, outputAmount, relayer, uint32(block.timestamp), fillDeadline, sig)
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(implementation), encoded, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(inputToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(inputToken.balanceOf(relayer), defaultParams.executionFee, "Relayer should receive execution fee");
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should have received net amount");
    }

    function testDepositorIsCloneAddress() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(
            spokePool.lastDepositor(),
            bytes32(uint256(uint160(depositAddress))),
            "Depositor should be the clone address"
        );
        assertEq(spokePool.lastRecipient(), defaultParams.recipient, "Recipient should match params");
    }

    function testFillDeadlinePassedThrough() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 7200; // 2 hours

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(spokePool.lastFillDeadline(), fillDeadline, "fillDeadline should be passed through directly");
        assertEq(spokePool.lastExclusivityDeadline(), 0, "exclusivityDeadline should be 0 when period is 0");
    }

    function testFillDeadlineWithExclusivity() public {
        SpokePoolImmutables memory params = defaultParams;
        params.exclusivityDeadline = 300; // 5 minutes
        params.exclusiveRelayer = bytes32(uint256(uint160(relayer)));
        bytes memory encoded = abi.encode(params);
        bytes32 salt = keccak256("test-salt-excl");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), encoded, salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(
            spokePool.lastExclusivityDeadline(),
            params.exclusivityDeadline,
            "exclusivityDeadline should be passed through to SpokePool"
        );
    }

    function testInvalidSignatureReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        // Sign with wrong key
        uint256 wrongKey = 0xBEEF;
        bytes32 structHash = keccak256(abi.encode(EXECUTE_DEPOSIT_TYPEHASH, inputAmount, outputAmount, fillDeadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(depositAddress), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            badSig
        );
    }

    function testExcessiveRelayerFeeReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=93e6
        // relayerFee = 99e6 - 93e6 = 6e6, totalFee = 6e6 + 1e6 = 7e6
        // totalFeeBps = 7e6 * 10000 / 100e6 = 700 > maxFeeBps (600)
        uint256 outputAmount = 93e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.MaxFee.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );
    }

    function testRelayerFeeAtMaxPasses() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=94e6
        // relayerFee = 99e6 - 94e6 = 5e6, totalFee = 5e6 + 1e6 = 6e6
        // totalFeeBps = 6e6 * 10000 / 100e6 = 600 = maxFeeBps (600)
        uint256 outputAmount = 94e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(spokePool.callCount(), 1, "Deposit should succeed at max fee boundary");
        assertEq(spokePool.lastOutputAmount(), outputAmount, "outputAmount should be passed through");
    }

    function testExecuteWithInsufficientBalance() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, 50e6);

        vm.expectRevert(ICounterfactualDeposit.InsufficientBalance.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
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
        CounterfactualDepositSpokePool(depositAddress).adminWithdraw(defaultParams, address(wrongToken), admin, 100e18);

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(user);
        CounterfactualDepositSpokePool(depositAddress).adminWithdraw(defaultParams, address(inputToken), user, 100e6);
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(depositAddress, address(inputToken), user, 100e6);

        vm.prank(user);
        CounterfactualDepositSpokePool(depositAddress).userWithdraw(defaultParams, address(inputToken), user, 100e6);

        assertEq(inputToken.balanceOf(user), 1000e6, "User should have all tokens back");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).userWithdraw(defaultParams, address(inputToken), relayer, 100e6);
    }

    function testInvalidParamsHash() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        SpokePoolImmutables memory wrongParams = defaultParams;
        wrongParams.maxFeeBps = 9999;

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            wrongParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );
    }

    function testCrossCloneReplayPrevention() public {
        // Deploy two clones with different salts but same params
        bytes32 salt1 = keccak256("salt-1");
        bytes32 salt2 = keccak256("salt-2");
        bytes memory encoded = _encodedParams();
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address clone1 = factory.deploy(address(implementation), encoded, salt1);
        address clone2 = factory.deploy(address(implementation), encoded, salt2);

        // Sign for clone1
        bytes memory sig = _signExecuteDeposit(clone1, inputAmount, outputAmount, fillDeadline);

        // Fund both clones
        vm.prank(user);
        inputToken.transfer(clone1, inputAmount);
        inputToken.mint(user, inputAmount);
        vm.prank(user);
        inputToken.transfer(clone2, inputAmount);

        // Execute on clone1 should work
        vm.prank(relayer);
        CounterfactualDepositSpokePool(clone1).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        // Replay the same signature on clone2 should fail (different domain separator)
        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(clone2).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );
    }

    function testExecuteWithZeroExecutionFee() public {
        SpokePoolImmutables memory params = defaultParams;
        params.executionFee = 0;
        bytes memory encoded = abi.encode(params);
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), encoded, salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(inputToken.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(spokePool.lastInputAmount(), inputAmount, "Full amount should be deposited");
    }

    function testExecuteOnImplementationReverts() public {
        vm.expectRevert();
        implementation.executeDeposit(
            defaultParams,
            100e6,
            98e6,
            relayer,
            uint32(block.timestamp),
            uint32(block.timestamp) + 3600,
            "sig"
        );
    }

    function testInvalidParamsHashOnWithdraw() public {
        bytes32 salt = keccak256("test-salt");
        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);

        SpokePoolImmutables memory wrongParams = defaultParams;
        wrongParams.maxFeeBps = 9999;

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(admin);
        CounterfactualDepositSpokePool(depositAddress).adminWithdraw(wrongParams, address(inputToken), admin, 100e6);

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(user);
        CounterfactualDepositSpokePool(depositAddress).userWithdraw(wrongParams, address(inputToken), user, 100e6);
    }

    function testZeroRelayerFee() public {
        bytes32 salt = keccak256("test-salt-zero-relay");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=99e6
        // outputInInputToken = 99e6 >= depositAmount → relayerFee = 0
        // totalFee = 0 + 1e6 = 1e6, feeBps = 100 < maxFeeBps (600)
        uint256 outputAmount = 99e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _encodedParams(), salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(spokePool.callCount(), 1, "Deposit should succeed with zero relayer fee");
        assertEq(spokePool.lastOutputAmount(), outputAmount, "outputAmount should be passed through");
    }

    function testDepositWithMessage() public {
        SpokePoolImmutables memory params = defaultParams;
        params.message = abi.encode(uint256(42), "hello");
        bytes memory encoded = abi.encode(params);
        bytes32 salt = keccak256("test-salt-msg");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), encoded, salt);
        bytes memory sig = _signExecuteDeposit(depositAddress, inputAmount, outputAmount, fillDeadline);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(depositAddress).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            sig
        );

        assertEq(keccak256(spokePool.lastMessage()), keccak256(params.message), "Message should be forwarded");
    }
}
