// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositSpokePool, SpokePoolImmutables, SpokePoolDepositParams, SpokePoolExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SpokePool that records deposit parameters. Accepts native ETH when msg.value > 0.
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
    uint256 public lastMsgValue;

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
        if (msg.value > 0) {
            require(msg.value == inputAmount, "MockSpokePool: msg.value mismatch");
        } else {
            address tokenAddr = address(uint160(uint256(inputToken)));
            IERC20(tokenAddr).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

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
        lastMsgValue = msg.value;
        callCount++;
    }
}

contract CounterfactualSpokePoolDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositSpokePool public implementation;
    MockSpokePool public spokePool;
    MintableERC20 public inputToken;
    address public weth;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    address public userWithdrawAddr;

    SpokePoolImmutables internal defaultParams;
    SpokePoolImmutables internal nativeParams;

    // EIP-712 constants (must match contract)
    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerPrivateKey = 0xA11CE;
        signerAddr = vm.addr(signerPrivateKey);
        userWithdrawAddr = user;

        inputToken = new MintableERC20("USDC", "USDC", 6);
        weth = makeAddr("weth");

        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositSpokePool(address(spokePool), signerAddr, weth);

        inputToken.mint(user, 1000e6);

        defaultParams = SpokePoolImmutables({
            depositParams: SpokePoolDepositParams({
                destinationChainId: 42161, // Arbitrum
                inputToken: bytes32(uint256(uint160(address(inputToken)))),
                outputToken: bytes32(uint256(uint160(address(inputToken)))), // Same token
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                message: ""
            }),
            executionParams: SpokePoolExecutionParams({
                stableExchangeRate: 1e18, // 1:1
                maxFeeFixed: 1e6, // 1 USDC fixed
                maxFeeBps: 500, // 5% variable
                executionFee: 1e6, // 1 USDC
                userWithdrawAddress: userWithdrawAddr,
                adminWithdrawAddress: admin
            })
        });

        nativeParams = SpokePoolImmutables({
            depositParams: SpokePoolDepositParams({
                destinationChainId: 42161,
                inputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
                outputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                message: ""
            }),
            executionParams: SpokePoolExecutionParams({
                stableExchangeRate: 1e18,
                maxFeeFixed: 0.01 ether, // fixed component
                maxFeeBps: 500, // 5% variable
                executionFee: 0.01 ether,
                userWithdrawAddress: userWithdrawAddr,
                adminWithdrawAddress: admin
            })
        });
    }

    function _nativeParamsHash() internal view returns (bytes32) {
        return keccak256(abi.encode(nativeParams));
    }

    function _paramsHash() internal view returns (bytes32) {
        return keccak256(abi.encode(defaultParams));
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signExecuteDeposit(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                exclusiveRelayer,
                exclusivityDeadline,
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        address deployed = factory.deploy(address(implementation), _paramsHash(), salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionParams.executionFee; // 99 USDC
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes32 paramsHash = _paramsHash();
        address depositAddress = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectEmit(true, true, true, true);
        emit CounterfactualDepositSpokePool.SpokePoolDepositExecuted(
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (
                defaultParams,
                inputAmount,
                outputAmount,
                bytes32(0),
                0,
                relayer,
                uint32(block.timestamp),
                fillDeadline,
                uint32(block.timestamp) + 3600,
                sig
            )
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(implementation), paramsHash, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(inputToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            inputToken.balanceOf(relayer),
            defaultParams.executionParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should have received net amount");
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (
                defaultParams,
                inputAmount,
                outputAmount,
                bytes32(0),
                0,
                relayer,
                uint32(block.timestamp),
                fillDeadline,
                uint32(block.timestamp) + 3600,
                sig
            )
        );

        vm.prank(relayer);
        factory.execute(depositAddress, executeCalldata);

        assertEq(inputToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            inputToken.balanceOf(relayer),
            defaultParams.executionParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should have received net amount");
    }

    function testDepositorIsCloneAddress() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(
            spokePool.lastDepositor(),
            bytes32(uint256(uint160(depositAddress))),
            "Depositor should be the clone address"
        );
        assertEq(spokePool.lastRecipient(), defaultParams.depositParams.recipient, "Recipient should match params");
    }

    function testFillDeadlinePassedThrough() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 7200; // 2 hours

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(spokePool.lastFillDeadline(), fillDeadline, "fillDeadline should be passed through directly");
        assertEq(spokePool.lastExclusivityDeadline(), 0, "exclusivityDeadline should be 0 when period is 0");
    }

    function testFillDeadlineWithExclusivity() public {
        bytes32 salt = keccak256("test-salt-excl");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes32 exclusiveRelayer = bytes32(uint256(uint160(relayer)));
        uint32 exclusivityDeadline = 300; // 5 minutes

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(
            spokePool.lastExclusivityDeadline(),
            exclusivityDeadline,
            "exclusivityDeadline should be passed through to SpokePool"
        );
        assertEq(
            spokePool.lastExclusiveRelayer(),
            exclusiveRelayer,
            "exclusiveRelayer should be passed through to SpokePool"
        );
    }

    function testInvalidSignatureReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        // Sign with wrong key
        uint256 wrongKey = 0xBEEF;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                bytes32(0),
                uint32(0),
                uint32(block.timestamp),
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(depositAddress), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline,
            badSig
        );
    }

    function testExpiredSignatureReverts() public {
        bytes32 salt = keccak256("test-salt-expired");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 100;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.warp(block.timestamp + 101);

        vm.expectRevert(ICounterfactualDeposit.SignatureExpired.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline,
            sig
        );
    }

    function testExcessiveRelayerFeeReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=92e6
        // relayerFee = 99e6 - 92e6 = 7e6, totalFee = 7e6 + 1e6 = 8e6
        // maxFee = maxFeeFixed + (maxFeeBps * inputAmount) / 10000 = 1e6 + (500 * 100e6) / 10000 = 1e6 + 5e6 = 6e6
        // totalFee (8e6) > maxFee (6e6) → revert
        uint256 outputAmount = 92e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.MaxFee.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testRelayerFeeAtMaxPasses() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=94e6
        // relayerFee = 99e6 - 94e6 = 5e6, totalFee = 5e6 + 1e6 = 6e6
        // maxFee = 1e6 + (500 * 100e6) / 10000 = 1e6 + 5e6 = 6e6
        // totalFee (6e6) = maxFee (6e6) → passes
        uint256 outputAmount = 94e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(spokePool.callCount(), 1, "Deposit should succeed at max fee boundary");
        assertEq(spokePool.lastOutputAmount(), outputAmount, "outputAmount should be passed through");
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(wrongToken), admin, 100e18);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).adminWithdraw(
            abi.encode(defaultParams),
            address(wrongToken),
            admin,
            100e18
        );

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(user);
        ICounterfactualDeposit(depositAddress).adminWithdraw(
            abi.encode(defaultParams),
            address(inputToken),
            user,
            100e6
        );
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(address(inputToken), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).userWithdraw(
            abi.encode(defaultParams),
            address(inputToken),
            user,
            100e6
        );

        assertEq(inputToken.balanceOf(user), 1000e6, "User should have all tokens back");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).userWithdraw(
            abi.encode(defaultParams),
            address(inputToken),
            relayer,
            100e6
        );
    }

    function testInvalidParamsHash() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        SpokePoolImmutables memory wrongParams = defaultParams;
        wrongParams.executionParams.maxFeeBps = 9999;

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            wrongParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testCrossCloneReplayPrevention() public {
        // Deploy two clones with different salts but same params
        bytes32 salt1 = keccak256("salt-1");
        bytes32 salt2 = keccak256("salt-2");
        bytes32 paramsHash = _paramsHash();
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address clone1 = factory.deploy(address(implementation), paramsHash, salt1);
        address clone2 = factory.deploy(address(implementation), paramsHash, salt2);

        // Sign for clone1
        bytes memory sig = _signExecuteDeposit(
            clone1,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        // Fund both clones
        vm.prank(user);
        inputToken.transfer(clone1, inputAmount);
        inputToken.mint(user, inputAmount);
        vm.prank(user);
        inputToken.transfer(clone2, inputAmount);

        // Execute on clone1 should work
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(clone1)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        // Replay the same signature on clone2 should fail (different domain separator)
        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(clone2)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testExecuteWithZeroExecutionFee() public {
        SpokePoolImmutables memory params = defaultParams;
        params.executionParams.executionFee = 0;
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(params)), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
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
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            uint32(block.timestamp) + 3600,
            uint32(block.timestamp) + 3600,
            "sig"
        );
    }

    function testInvalidParamsHashOnWithdraw() public {
        bytes32 salt = keccak256("test-salt");
        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        SpokePoolImmutables memory wrongParams = defaultParams;
        wrongParams.executionParams.maxFeeBps = 9999;

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).adminWithdraw(
            abi.encode(wrongParams),
            address(inputToken),
            admin,
            100e6
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(user);
        ICounterfactualDeposit(depositAddress).userWithdraw(abi.encode(wrongParams), address(inputToken), user, 100e6);
    }

    function testZeroRelayerFee() public {
        bytes32 salt = keccak256("test-salt-zero-relay");
        uint256 inputAmount = 100e6;
        // price=1e18 (1:1), depositAmount=99e6, outputAmount=99e6
        // outputInInputToken = 99e6 >= depositAmount → relayerFee = 0
        // totalFee = 0 + 1e6 = 1e6, maxFee = 1e6 + 5e6 = 6e6 → passes
        uint256 outputAmount = 99e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(spokePool.callCount(), 1, "Deposit should succeed with zero relayer fee");
        assertEq(spokePool.lastOutputAmount(), outputAmount, "outputAmount should be passed through");
    }

    function testDepositWithMessage() public {
        SpokePoolImmutables memory params = defaultParams;
        params.depositParams.message = abi.encode(uint256(42), "hello");
        bytes32 salt = keccak256("test-salt-msg");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(params)), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(
            keccak256(spokePool.lastMessage()),
            keccak256(params.depositParams.message),
            "Message should be forwarded"
        );
    }

    // --- Native ETH tests ---

    function testNativeDeployAndExecute() public {
        bytes32 salt = keccak256("native-salt");
        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.98 ether;
        uint256 expectedDeposit = inputAmount - nativeParams.executionParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes32 paramsHash = _nativeParamsHash();
        address depositAddress = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        // Send native ETH to the predicted address
        vm.deal(depositAddress, inputAmount);

        vm.expectEmit(true, true, true, true);
        emit CounterfactualDepositSpokePool.SpokePoolDepositExecuted(
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (
                nativeParams,
                inputAmount,
                outputAmount,
                bytes32(0),
                0,
                relayer,
                uint32(block.timestamp),
                fillDeadline,
                uint32(block.timestamp) + 3600,
                sig
            )
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(implementation), paramsHash, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(depositAddress.balance, 0, "Clone should have no ETH left");
        assertEq(
            relayer.balance,
            nativeParams.executionParams.executionFee,
            "Relayer should receive execution fee in ETH"
        );
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should have received net amount");
        assertEq(spokePool.lastMsgValue(), expectedDeposit, "SpokePool should have received ETH via msg.value");
        assertEq(
            spokePool.lastInputToken(),
            bytes32(uint256(uint160(weth))),
            "SpokePool should receive wrappedNativeToken as inputToken"
        );
    }

    function testNativeExecuteFeeCheck() public {
        bytes32 salt = keccak256("native-fee-check");
        uint256 inputAmount = 1 ether;
        // relayerFee = 0.99e18 - 0.93e18 = 0.06e18, totalFee = 0.06e18 + 0.01e18 = 0.07e18
        // maxFee = 0.01e18 + (500 * 1e18) / 10000 = 0.01e18 + 0.05e18 = 0.06e18
        // totalFee (0.07e18) > maxFee (0.06e18) → revert
        uint256 outputAmount = 0.93 ether;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _nativeParamsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.deal(depositAddress, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.MaxFee.selector);
        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            nativeParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testNativeZeroExecutionFee() public {
        SpokePoolImmutables memory params = nativeParams;
        params.executionParams.executionFee = 0;
        bytes32 salt = keccak256("native-zero-fee");
        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.98 ether;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(params)), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.deal(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            params,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(relayer.balance, 0, "Relayer should receive no fee");
        assertEq(spokePool.lastInputAmount(), inputAmount, "Full amount should be deposited");
        assertEq(spokePool.lastMsgValue(), inputAmount, "Full amount sent as msg.value");
    }

    function testNativeUserWithdraw() public {
        bytes32 salt = keccak256("native-user-withdraw");
        address depositAddress = factory.deploy(address(implementation), _nativeParamsHash(), salt);
        address nativeAsset = implementation.NATIVE_ASSET();

        vm.deal(depositAddress, 1 ether);

        uint256 userBalBefore = user.balance;

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(nativeAsset, user, 1 ether);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).userWithdraw(abi.encode(nativeParams), nativeAsset, user, 1 ether);

        assertEq(user.balance - userBalBefore, 1 ether, "User should receive ETH");
        assertEq(depositAddress.balance, 0, "Clone should have no ETH");
    }

    function testNativeAdminWithdraw() public {
        bytes32 salt = keccak256("native-admin-withdraw");
        address depositAddress = factory.deploy(address(implementation), _nativeParamsHash(), salt);
        address nativeAsset = implementation.NATIVE_ASSET();

        vm.deal(depositAddress, 1 ether);

        uint256 adminBalBefore = admin.balance;

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(nativeAsset, admin, 1 ether);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).adminWithdraw(abi.encode(nativeParams), nativeAsset, admin, 1 ether);

        assertEq(admin.balance - adminBalBefore, 1 ether, "Admin should receive ETH");
    }

    function testNativeReceiveAfterDeployment() public {
        bytes32 salt = keccak256("native-receive");
        address depositAddress = factory.deploy(address(implementation), _nativeParamsHash(), salt);

        // Send ETH after deployment
        vm.deal(user, 2 ether);
        vm.prank(user);
        (bool success, ) = depositAddress.call{ value: 1 ether }("");
        assertTrue(success, "Should accept ETH via receive()");
        assertEq(depositAddress.balance, 1 ether, "Clone should hold ETH");
    }

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes32 paramsHash = _paramsHash();
        address depositAddress = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        bytes memory sig1 = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        bytes memory executeCalldata1 = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (
                defaultParams,
                inputAmount,
                outputAmount,
                bytes32(0),
                0,
                relayer,
                uint32(block.timestamp),
                fillDeadline,
                uint32(block.timestamp) + 3600,
                sig1
            )
        );

        // First call deploys and executes
        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(
            address(implementation),
            paramsHash,
            salt,
            executeCalldata1
        );
        assertEq(deployed, depositAddress, "Should return predicted address");
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "First deposit should execute");

        // Second call with clone already deployed — should not revert
        inputToken.mint(user, inputAmount);
        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        bytes memory sig2 = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        bytes memory executeCalldata2 = abi.encodeCall(
            CounterfactualDepositSpokePool.executeDeposit,
            (
                defaultParams,
                inputAmount,
                outputAmount,
                bytes32(0),
                0,
                relayer,
                uint32(block.timestamp),
                fillDeadline,
                uint32(block.timestamp) + 3600,
                sig2
            )
        );

        vm.prank(relayer);
        address deployed2 = factory.deployIfNeededAndExecute(
            address(implementation),
            paramsHash,
            salt,
            executeCalldata2
        );
        assertEq(deployed2, depositAddress, "Should return same address");
        assertEq(spokePool.callCount(), 2, "Both deposits should execute");
    }

    function testErc20DepositUsesErc20Flow() public {
        // When inputToken is a regular ERC20 (not NATIVE_ASSET), ERC20 flow is used
        bytes32 salt = keccak256("erc20-flow");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositSpokePool(payable(depositAddress)).executeDeposit(
            defaultParams,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(spokePool.lastMsgValue(), 0, "Should use ERC20 flow (no msg.value)");
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should receive net amount");
        assertEq(inputToken.balanceOf(relayer), defaultParams.executionParams.executionFee, "Relayer gets ERC20 fee");
    }
}
