// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { TransferProxy } from "../../../../contracts/TransferProxy.sol";
import { SpokePoolPeriphery, SwapProxy } from "../../../../contracts/SpokePoolPeriphery.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolPeripheryInterface } from "../../../../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { AcrossMessageHandler } from "../../../../contracts/interfaces/SpokePoolMessageHandler.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";
import { MockPermit2, Permit2EIP712 } from "../../../../contracts/test/MockPermit2.sol";
import { PeripherySigningLib } from "../../../../contracts/libraries/PeripherySigningLib.sol";
import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { AddressToBytes32 } from "../../../../contracts/libraries/AddressConverters.sol";

contract Exchange {
    IPermit2 permit2;

    constructor(IPermit2 _permit2) {
        permit2 = _permit2;
    }

    function swap(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 amountOutMin, bool usePermit2) external {
        if (tokenIn.balanceOf(address(this)) >= amountIn) {
            tokenIn.transfer(address(1), amountIn);
            require(tokenOut.transfer(msg.sender, amountOutMin));
            return;
        }
        if (usePermit2) {
            permit2.transferFrom(msg.sender, address(this), uint160(amountIn), address(tokenIn));
            tokenOut.transfer(msg.sender, amountOutMin);
            return;
        }
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn));
        require(tokenOut.transfer(msg.sender, amountOutMin));
    }
}

contract HashUtils {
    function hashSwapAndDepositData(
        SpokePoolPeriphery.SwapAndDepositData calldata swapAndDepositData
    ) external pure returns (bytes32) {
        return PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData);
    }
}

/// @dev Simple target contract that records calls from the MulticallHandler.
contract RecordingTarget {
    address public lastToken;
    uint256 public lastAmount;
    bool public wasCalled;

    function recordTransfer(address token, uint256 amount) external {
        lastToken = token;
        lastAmount = amount;
        wasCalled = true;
    }
}

contract TransferProxyTest is Test {
    using AddressToBytes32 for address;

    TransferProxy transferProxy;
    SpokePoolPeriphery spokePoolPeriphery;
    HashUtils hashUtils;
    Exchange dex;
    IPermit2 permit2;
    MulticallHandler multicallHandler;

    WETH9Interface mockWETH;
    MockERC20 mockERC20;

    address depositor;
    address owner;
    address recipient;
    address relayer;

    uint256 mintAmount = 10 ** 22;
    uint256 submissionFeeAmount = 1;
    uint256 depositAmount = 5 * (10 ** 18);
    uint256 mintAmountWithSubmissionFee = mintAmount + submissionFeeAmount;
    uint32 fillDeadlineBuffer = 7200;
    uint256 privateKey = 0x12345678910;

    bytes32 domainSeparator;
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    string private constant PERMIT_TRANSFER_TYPE_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256(abi.encodePacked(PeripherySigningLib.TOKEN_PERMISSIONS_TYPE));

    function setUp() public {
        hashUtils = new HashUtils();

        mockWETH = WETH9Interface(address(new WETH9()));
        mockERC20 = new MockERC20();

        depositor = vm.addr(privateKey);
        owner = vm.addr(2);
        recipient = vm.addr(3);
        relayer = vm.addr(4);
        permit2 = IPermit2(new MockPermit2());
        dex = new Exchange(permit2);
        multicallHandler = new MulticallHandler();

        vm.startPrank(owner);
        spokePoolPeriphery = new SpokePoolPeriphery(permit2);
        domainSeparator = Permit2EIP712(address(permit2)).DOMAIN_SEPARATOR();
        transferProxy = new TransferProxy();
        vm.stopPrank();

        deal(depositor, mintAmountWithSubmissionFee);
        deal(address(mockERC20), depositor, mintAmountWithSubmissionFee, true);
        deal(address(mockERC20), address(dex), depositAmount, true);
        vm.startPrank(depositor);
        mockWETH.deposit{ value: mintAmountWithSubmissionFee }();
        mockERC20.approve(address(spokePoolPeriphery), mintAmountWithSubmissionFee);
        IERC20(address(mockWETH)).approve(address(spokePoolPeriphery), mintAmountWithSubmissionFee);

        // Approve permit2
        IERC20(address(mockWETH)).approve(address(permit2), mintAmountWithSubmissionFee * 10);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // Direct deposit/unsafeDeposit tests
    // ──────────────────────────────────────────────────────────────

    function testDeposit() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);
        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid,
            bytes32(0), // exclusiveRelayer (ignored)
            0, // quoteTimestamp (ignored)
            0, // fillDeadline (ignored)
            0, // exclusivityDeadline (ignored)
            "" // message
        );
        vm.stopPrank();

        assertEq(mockERC20.balanceOf(recipient), amount, "Recipient should receive tokens via deposit()");
    }

    function testUnsafeDeposit() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);
        transferProxy.unsafeDeposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid,
            bytes32(0), // exclusiveRelayer (ignored)
            0, // depositNonce (ignored)
            0, // quoteTimestamp (ignored)
            0, // fillDeadline (ignored)
            0, // exclusivityParameter (ignored)
            "" // message
        );
        vm.stopPrank();

        assertEq(mockERC20.balanceOf(recipient), amount, "Recipient should receive tokens via unsafeDeposit()");
    }

    function testDepositEmitsEvent() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);

        vm.expectEmit(address(transferProxy));
        emit TransferProxy.Transfer(address(mockERC20), recipient, amount);

        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid,
            bytes32(0),
            0,
            0,
            0,
            ""
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // Safety checks
    // ──────────────────────────────────────────────────────────────

    function testDepositRevertsOnWrongChainId() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);

        vm.expectRevert(TransferProxy.InvalidDestinationChainId.selector);
        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid + 1, // wrong chain
            bytes32(0),
            0,
            0,
            0,
            ""
        );
        vm.stopPrank();
    }

    function testUnsafeDepositRevertsOnWrongChainId() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);

        vm.expectRevert(TransferProxy.InvalidDestinationChainId.selector);
        transferProxy.unsafeDeposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            999, // wrong chain
            bytes32(0),
            0,
            0,
            0,
            0,
            ""
        );
        vm.stopPrank();
    }

    function testDepositRevertsOnMismatchedOutputToken() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);

        vm.expectRevert(TransferProxy.InvalidOutputToken.selector);
        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockWETH).toBytes32(), // different token
            amount,
            amount,
            block.chainid,
            bytes32(0),
            0,
            0,
            0,
            ""
        );
        vm.stopPrank();
    }

    function testDepositRevertsOnMismatchedOutputAmount() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);

        vm.expectRevert(TransferProxy.InvalidOutputAmount.selector);
        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount - 1, // different amount
            block.chainid,
            bytes32(0),
            0,
            0,
            0,
            ""
        );
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // Message execution (handleV3AcrossMessage)
    // ──────────────────────────────────────────────────────────────

    function testDepositCallsHandleMessageOnContractRecipient() public {
        RecordingTarget target = new RecordingTarget();
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        // Build MulticallHandler instructions: transfer tokens from handler to the recording target.
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](1);
        calls[0] = MulticallHandler.Call({
            target: address(target),
            callData: abi.encodeWithSelector(RecordingTarget.recordTransfer.selector, address(mockERC20), amount),
            value: 0
        });
        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            fallbackRecipient: recipient
        });
        bytes memory message = abi.encode(instructions);

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);
        transferProxy.deposit(
            depositor.toBytes32(),
            address(multicallHandler).toBytes32(),
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid,
            bytes32(0),
            0,
            0,
            0,
            message
        );
        vm.stopPrank();

        assertTrue(target.wasCalled(), "MulticallHandler should have called target");
        assertEq(target.lastToken(), address(mockERC20), "Target should see correct token");
        assertEq(target.lastAmount(), amount, "Target should see correct amount");
    }

    function testDepositSkipsMessageForEOARecipient() public {
        uint256 amount = 1 ether;
        deal(address(mockERC20), depositor, amount, true);

        // Pass non-empty message but recipient is an EOA — should not revert.
        bytes memory message = abi.encode("some data");

        vm.startPrank(depositor);
        mockERC20.approve(address(transferProxy), amount);
        transferProxy.deposit(
            depositor.toBytes32(),
            recipient.toBytes32(), // EOA
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            amount,
            amount,
            block.chainid,
            bytes32(0),
            0,
            0,
            0,
            message
        );
        vm.stopPrank();

        assertEq(mockERC20.balanceOf(recipient), amount, "EOA recipient should receive tokens even with message");
    }

    // ──────────────────────────────────────────────────────────────
    // Integration: swapAndBridge with TransferProxy
    // ──────────────────────────────────────────────────────────────

    function testSwapAndBridgeWithTransferProxy() public {
        vm.startPrank(depositor);

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            0,
            address(0),
            dex,
            SpokePoolPeripheryInterface.TransferType.Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            false,
            0
        );
        data.depositData.recipient = recipient.toBytes32();

        uint256 recipientBefore = mockERC20.balanceOf(recipient);

        spokePoolPeriphery.swapAndBridge(data);
        vm.stopPrank();

        assertEq(
            mockERC20.balanceOf(recipient) - recipientBefore,
            depositAmount,
            "Recipient should receive swap output via TransferProxy"
        );
    }

    function testSwapAndBridgeWithPermit2AndTransferProxy() public {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor,
            false,
            permit.nonce
        );
        data.depositData.recipient = recipient.toBytes32();

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typehash,
                        tokenPermissions,
                        address(spokePoolPeriphery),
                        permit.nonce,
                        permit.deadline,
                        hashUtils.hashSwapAndDepositData(data)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        uint256 recipientBefore = mockERC20.balanceOf(recipient);

        spokePoolPeriphery.swapAndBridgeWithPermit2(depositor, data, permit, signature);

        assertEq(
            mockERC20.balanceOf(recipient) - recipientBefore,
            depositAmount,
            "Recipient should receive swap output via permit2 + TransferProxy"
        );
        assertEq(mockWETH.balanceOf(relayer), submissionFeeAmount, "Relayer should receive submission fee");
    }

    function testSwapAndBridgeWithPermitAndTransferProxy() public {
        // Deal the exchange some WETH since we swap a permit ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            false,
            spokePoolPeriphery.permitNonces(depositor)
        );
        data.depositData.recipient = recipient.toBytes32();

        bytes32 nonce = 0;

        // Get the permit signature.
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.PERMIT_TYPEHASH_EXTERNAL(),
                depositor,
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                nonce,
                block.timestamp
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory permitSignature = bytes.concat(r, s, bytes1(v));

        // Get the swap and deposit data signature.
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashSwapAndDepositData(data))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory dataSignature = bytes.concat(_r, _s, bytes1(_v));

        uint256 recipientBefore = IERC20(address(mockWETH)).balanceOf(recipient);

        spokePoolPeriphery.swapAndBridgeWithPermit(depositor, data, block.timestamp, permitSignature, dataSignature);

        assertEq(
            IERC20(address(mockWETH)).balanceOf(recipient) - recipientBefore,
            depositAmount,
            "Recipient should receive swap output via permit + TransferProxy"
        );
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount, "Relayer should receive submission fee");
    }

    function testSwapAndBridgeWithAuthorizationAndTransferProxy() public {
        // Deal the exchange some WETH since we swap a EIP-3009 ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            false,
            0
        );
        data.depositData.recipient = recipient.toBytes32();

        // Compute the witness that will be used as the ERC-3009 nonce.
        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(data))
        );

        // Get the transfer with auth signature using the witness to bind the intent.
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                depositor,
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                block.timestamp,
                block.timestamp,
                witness
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        uint256 recipientBefore = IERC20(address(mockWETH)).balanceOf(recipient);

        spokePoolPeriphery.swapAndBridgeWithAuthorization(depositor, data, block.timestamp, block.timestamp, signature);

        assertEq(
            IERC20(address(mockWETH)).balanceOf(recipient) - recipientBefore,
            depositAmount,
            "Recipient should receive swap output via authorization + TransferProxy"
        );
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount, "Relayer should receive submission fee");
    }

    function testSubmissionFeesWithTransferProxy() public {
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor,
            false,
            permit.nonce
        );
        data.depositData.recipient = recipient.toBytes32();

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typehash,
                        tokenPermissions,
                        address(spokePoolPeriphery),
                        permit.nonce,
                        permit.deadline,
                        hashUtils.hashSwapAndDepositData(data)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        uint256 relayerBefore = mockWETH.balanceOf(relayer);

        spokePoolPeriphery.swapAndBridgeWithPermit2(depositor, data, permit, signature);

        assertEq(
            mockWETH.balanceOf(relayer) - relayerBefore,
            submissionFeeAmount,
            "Submission fees should be paid correctly in gasless TransferProxy flow"
        );
    }

    function testSwapAndBridgeRevertsOnMismatchedOutputAmount() public {
        vm.startPrank(depositor);

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            0,
            address(0),
            dex,
            SpokePoolPeripheryInterface.TransferType.Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            false,
            0
        );
        data.depositData.recipient = recipient.toBytes32();
        // Set outputAmount to a value different from actual swap output — TransferProxy should reject it.
        data.depositData.outputAmount = 999;

        vm.expectRevert(TransferProxy.InvalidOutputAmount.selector);
        spokePoolPeriphery.swapAndBridge(data);
        vm.stopPrank();
    }

    // ──────────────────────────────────────────────────────────────
    // Integration: swap + MulticallHandler via TransferProxy
    // ──────────────────────────────────────────────────────────────

    function testSwapAndBridgeWithMulticallMessage() public {
        RecordingTarget target = new RecordingTarget();

        // Build MulticallHandler instructions.
        MulticallHandler.Call[] memory calls = new MulticallHandler.Call[](1);
        calls[0] = MulticallHandler.Call({
            target: address(target),
            callData: abi.encodeWithSelector(
                RecordingTarget.recordTransfer.selector,
                address(mockERC20),
                depositAmount
            ),
            value: 0
        });
        MulticallHandler.Instructions memory instructions = MulticallHandler.Instructions({
            calls: calls,
            fallbackRecipient: recipient
        });
        bytes memory message = abi.encode(instructions);

        vm.startPrank(depositor);

        SpokePoolPeripheryInterface.SwapAndDepositData memory data = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            0,
            address(0),
            dex,
            SpokePoolPeripheryInterface.TransferType.Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            false,
            0
        );
        data.depositData.recipient = address(multicallHandler).toBytes32();
        data.depositData.message = message;

        spokePoolPeriphery.swapAndBridge(data);
        vm.stopPrank();

        assertTrue(target.wasCalled(), "MulticallHandler should execute calls after swap");
        assertEq(target.lastToken(), address(mockERC20), "Target should see correct token");
        assertEq(target.lastAmount(), depositAmount, "Target should see correct amount");
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    function _defaultSwapAndDepositData(
        address _swapToken,
        uint256 _swapAmount,
        uint256 _feeAmount,
        address _feeRecipient,
        Exchange _exchange,
        SpokePoolPeripheryInterface.TransferType _transferType,
        address _inputToken,
        uint256 _amount,
        address _depositor,
        bool _enableProportionalAdjustment,
        uint256 _nonce
    ) internal view returns (SpokePoolPeriphery.SwapAndDepositData memory) {
        bool usePermit2 = _transferType == SpokePoolPeripheryInterface.TransferType.Permit2Approval;
        return
            SpokePoolPeripheryInterface.SwapAndDepositData({
                submissionFees: SpokePoolPeripheryInterface.Fees({ amount: _feeAmount, recipient: _feeRecipient }),
                depositData: SpokePoolPeripheryInterface.BaseDepositData({
                    inputToken: _inputToken,
                    outputToken: _inputToken.toBytes32(),
                    outputAmount: _amount,
                    depositor: _depositor,
                    recipient: _depositor.toBytes32(),
                    destinationChainId: block.chainid,
                    exclusiveRelayer: bytes32(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: _swapToken,
                exchange: address(_exchange),
                transferType: _transferType,
                swapTokenAmount: _swapAmount,
                minExpectedInputTokenAmount: _amount,
                routerCalldata: abi.encodeWithSelector(
                    _exchange.swap.selector,
                    IERC20(_swapToken),
                    IERC20(_inputToken),
                    _swapAmount,
                    _amount,
                    usePermit2
                ),
                enableProportionalAdjustment: _enableProportionalAdjustment,
                spokePool: address(transferProxy),
                nonce: _nonce
            });
    }
}
