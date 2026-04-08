// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualDepositSpokePool,
    SpokePoolDepositParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
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
    Merkle public merkle;
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositSpokePool public spokePoolImpl;
    WithdrawImplementation public withdrawImpl;
    MockSpokePool public spokePool;
    MintableERC20 public inputToken;
    address public weth;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    SpokePoolDepositParams internal defaultParams;
    SpokePoolDepositParams internal nativeParams;

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

        inputToken = new MintableERC20("USDC", "USDC", 6);
        weth = makeAddr("weth");

        merkle = new Merkle();
        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        spokePoolImpl = new CounterfactualDepositSpokePool(address(spokePool), signerAddr, weth);
        withdrawImpl = new WithdrawImplementation();

        inputToken.mint(user, 1000e6);

        defaultParams = SpokePoolDepositParams({
            destinationChainId: 42161, // Arbitrum
            inputToken: bytes32(uint256(uint160(address(inputToken)))),
            outputToken: bytes32(uint256(uint160(address(inputToken)))), // Same token
            recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            message: "",
            stableExchangeRate: 1e18, // 1:1
            maxFeeFixed: 1e6, // 1 USDC fixed
            maxFeeBps: 500, // 5% variable
            executionFee: 1e6 // 1 USDC
        });

        nativeParams = SpokePoolDepositParams({
            destinationChainId: 42161,
            inputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
            outputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
            recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            message: "",
            stableExchangeRate: 1e18,
            maxFeeFixed: 0.01 ether,
            maxFeeBps: 500,
            executionFee: 0.01 ether
        });
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    function _buildTreeAndDeploy(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address clone, bytes32[] memory depositProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        clone = factory.deploy(address(dispatcher), root, salt);
    }

    function _buildTreeAndPredict(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address predicted, bytes32 root, bytes32[] memory depositProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        root = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        predicted = factory.predictDepositAddress(address(dispatcher), root, salt);
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

    function _encodeSubmitterData(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes memory sig = _signExecuteDeposit(
            clone,
            inputAmount,
            outputAmount,
            exclusiveRelayer,
            exclusivityDeadline,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline
        );
        return
            abi.encode(
                SpokePoolSubmitterData({
                    inputAmount: inputAmount,
                    outputAmount: outputAmount,
                    exclusiveRelayer: exclusiveRelayer,
                    exclusivityDeadline: exclusivityDeadline,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: quoteTimestamp,
                    fillDeadline: fillDeadline,
                    signatureDeadline: signatureDeadline,
                    signature: sig
                })
            );
    }

    function testPredictDepositAddress() public {
        bytes memory paramsEncoded = abi.encode(defaultParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), paramsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(dispatcher), root, salt);
        address deployed = factory.deploy(address(dispatcher), root, salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32 root, bytes32[] memory proof) = _buildTreeAndPredict(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData, proof)
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(dispatcher), root, salt, executeCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(inputToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(inputToken.balanceOf(relayer), defaultParams.executionFee, "Relayer should receive execution fee");
        assertEq(spokePool.lastInputAmount(), expectedDeposit, "SpokePool should have received net amount");
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData, proof)
        );

        vm.prank(relayer);
        factory.execute(depositAddress, executeCalldata);

        assertEq(inputToken.balanceOf(depositAddress), 0);
        assertEq(inputToken.balanceOf(relayer), defaultParams.executionFee);
        assertEq(spokePool.lastInputAmount(), expectedDeposit);
    }

    function testDepositorIsCloneAddress() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(depositAddress))));
        assertEq(spokePool.lastRecipient(), defaultParams.recipient);
    }

    function testFillDeadlinePassedThrough() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 7200;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.lastFillDeadline(), fillDeadline);
        assertEq(spokePool.lastExclusivityDeadline(), 0);
    }

    function testFillDeadlineWithExclusivity() public {
        bytes32 salt = keccak256("test-salt-excl");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes32 exclusiveRelayer = bytes32(uint256(uint160(relayer)));
        uint32 exclusivityDeadline = 300;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.lastExclusivityDeadline(), exclusivityDeadline);
        assertEq(spokePool.lastExclusiveRelayer(), exclusiveRelayer);
    }

    function testInvalidSignatureReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        // Sign with wrong key
        uint256 wrongKey = 0xBEEF;
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

        bytes memory submitterData = abi.encode(
            SpokePoolSubmitterData({
                inputAmount: inputAmount,
                outputAmount: outputAmount,
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                executionFeeRecipient: relayer,
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: fillDeadline,
                signatureDeadline: signatureDeadline,
                signature: badSig
            })
        );

        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes32 salt = keccak256("test-salt-expired");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 100;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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

        vm.expectRevert(CounterfactualDepositSpokePool.SignatureExpired.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);
    }

    function testExcessiveRelayerFeeReverts() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 92e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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

        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);
    }

    function testRelayerFeeAtMaxPasses() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 94e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastOutputAmount(), outputAmount);
    }

    function testUserWithdraw() public {
        bytes memory depositParamsEncoded = abi.encode(defaultParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        bytes32 salt = keccak256("test-salt");
        address depositAddress = factory.deploy(address(dispatcher), root, salt);
        bytes32[] memory userProof = merkle.getProof(leaves, 1);

        vm.prank(user);
        inputToken.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(inputToken), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(inputToken), user, 100e6),
            userProof
        );

        assertEq(inputToken.balanceOf(user), 1000e6);
    }

    function testUserWithdrawUnauthorized() public {
        bytes memory depositParamsEncoded = abi.encode(defaultParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("test-salt"));
        bytes32[] memory userProof = merkle.getProof(leaves, 1);

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(inputToken), relayer, 100e6),
            userProof
        );
    }

    function testAdminWithdraw() public {
        bytes memory depositParamsEncoded = abi.encode(defaultParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("test-salt"));
        bytes32[] memory withdrawProof = merkle.getProof(leaves, 1);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(wrongToken), admin, 100e18);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(wrongToken), admin, 100e18),
            withdrawProof
        );

        assertEq(wrongToken.balanceOf(admin), 100e18);
    }

    function testAdminWithdrawUnauthorized() public {
        bytes memory depositParamsEncoded = abi.encode(defaultParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("test-salt"));
        bytes32[] memory withdrawProof = merkle.getProof(leaves, 1);

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(inputToken), relayer, 100e6),
            withdrawProof
        );
    }

    function testInvalidProofReverts() public {
        bytes32 salt = keccak256("test-salt");
        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        // Use different params to make proof invalid
        SpokePoolDepositParams memory wrongParams = defaultParams;
        wrongParams.maxFeeBps = 9999;

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), abi.encode(wrongParams), "", proof);
    }

    function testCrossCloneReplayPrevention() public {
        bytes32 salt1 = keccak256("salt-1");
        bytes32 salt2 = keccak256("salt-2");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);

        (address clone1, bytes32[] memory proof1) = _buildTreeAndDeploy(paramsEncoded, salt1);
        (address clone2, bytes32[] memory proof2) = _buildTreeAndDeploy(paramsEncoded, salt2);

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
        bytes memory submitterData = abi.encode(
            SpokePoolSubmitterData({
                inputAmount: inputAmount,
                outputAmount: outputAmount,
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                executionFeeRecipient: relayer,
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: fillDeadline,
                signatureDeadline: uint32(block.timestamp) + 3600,
                signature: sig
            })
        );

        // Fund both clones
        vm.prank(user);
        inputToken.transfer(clone1, inputAmount);
        inputToken.mint(user, inputAmount);
        vm.prank(user);
        inputToken.transfer(clone2, inputAmount);

        // Execute on clone1 should work
        vm.prank(relayer);
        ICounterfactualDeposit(clone1).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof1);

        // Replay on clone2 should fail (different domain separator)
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone2).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof2);
    }

    function testExecuteWithZeroExecutionFee() public {
        SpokePoolDepositParams memory params = defaultParams;
        params.executionFee = 0;
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(inputToken.balanceOf(relayer), 0);
        assertEq(spokePool.lastInputAmount(), inputAmount);
    }

    function testZeroRelayerFee() public {
        bytes32 salt = keccak256("test-salt-zero-relay");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 99e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastOutputAmount(), outputAmount);
    }

    function testDepositWithMessage() public {
        SpokePoolDepositParams memory params = defaultParams;
        params.message = abi.encode(uint256(42), "hello");
        bytes32 salt = keccak256("test-salt-msg");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(keccak256(spokePool.lastMessage()), keccak256(params.message));
    }

    // --- Native ETH tests ---

    function testNativeDeployAndExecute() public {
        bytes32 salt = keccak256("native-salt");
        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.98 ether;
        uint256 expectedDeposit = inputAmount - nativeParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(nativeParams);
        (address depositAddress, bytes32 root, bytes32[] memory proof) = _buildTreeAndPredict(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData, proof)
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(dispatcher), root, salt, executeCalldata);

        assertEq(deployed, depositAddress);
        assertEq(depositAddress.balance, 0);
        assertEq(relayer.balance, nativeParams.executionFee);
        assertEq(spokePool.lastInputAmount(), expectedDeposit);
        assertEq(spokePool.lastMsgValue(), expectedDeposit);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(weth))));
    }

    function testNativeExecuteFeeCheck() public {
        bytes32 salt = keccak256("native-fee-check");
        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.93 ether;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(nativeParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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

        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);
    }

    function testNativeZeroExecutionFee() public {
        SpokePoolDepositParams memory params = nativeParams;
        params.executionFee = 0;
        bytes32 salt = keccak256("native-zero-fee");
        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.98 ether;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(params);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(relayer.balance, 0);
        assertEq(spokePool.lastInputAmount(), inputAmount);
        assertEq(spokePool.lastMsgValue(), inputAmount);
    }

    function testNativeUserWithdraw() public {
        bytes memory nativeParamsEncoded = abi.encode(nativeParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), nativeParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("native-user-withdraw"));
        bytes32[] memory userProof = merkle.getProof(leaves, 1);

        vm.deal(depositAddress, 1 ether);

        uint256 userBalBefore = user.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(NATIVE_ASSET, user, 1 ether);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(NATIVE_ASSET, user, 1 ether),
            userProof
        );

        assertEq(user.balance - userBalBefore, 1 ether);
        assertEq(depositAddress.balance, 0);
    }

    function testNativeAdminWithdraw() public {
        bytes memory nativeParamsEncoded = abi.encode(nativeParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), nativeParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("native-admin-withdraw"));
        bytes32[] memory withdrawProof = merkle.getProof(leaves, 1);

        vm.deal(depositAddress, 1 ether);

        uint256 adminBalBefore = admin.balance;

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(NATIVE_ASSET, admin, 1 ether);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wp,
            abi.encode(NATIVE_ASSET, admin, 1 ether),
            withdrawProof
        );

        assertEq(admin.balance - adminBalBefore, 1 ether);
    }

    function testNativeReceiveAfterDeployment() public {
        bytes memory nativeParamsEncoded = abi.encode(nativeParams);
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(spokePoolImpl), nativeParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);

        bytes32 root = merkle.getRoot(leaves);
        address depositAddress = factory.deploy(address(dispatcher), root, keccak256("native-receive"));

        vm.deal(user, 2 ether);
        vm.prank(user);
        (bool success, ) = depositAddress.call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(depositAddress.balance, 1 ether);
    }

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32 root, bytes32[] memory proof) = _buildTreeAndPredict(paramsEncoded, salt);

        bytes memory submitterData1 = _encodeSubmitterData(
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
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData1, proof)
        );

        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata1);
        assertEq(deployed, depositAddress);
        assertEq(spokePool.lastInputAmount(), expectedDeposit);

        // Second call with clone already deployed
        inputToken.mint(user, inputAmount);
        vm.prank(user);
        inputToken.transfer(depositAddress, inputAmount);

        bytes memory submitterData2 = _encodeSubmitterData(
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
            CounterfactualDeposit.execute,
            (address(spokePoolImpl), paramsEncoded, submitterData2, proof)
        );

        vm.prank(relayer);
        address deployed2 = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata2);
        assertEq(deployed2, depositAddress);
        assertEq(spokePool.callCount(), 2);
    }

    function testErc20DepositUsesErc20Flow() public {
        bytes32 salt = keccak256("erc20-flow");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address depositAddress, bytes32[] memory proof) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
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
        ICounterfactualDeposit(depositAddress).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(spokePool.lastMsgValue(), 0);
        assertEq(spokePool.lastInputAmount(), expectedDeposit);
        assertEq(inputToken.balanceOf(relayer), defaultParams.executionFee);
    }
}
