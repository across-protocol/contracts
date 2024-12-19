// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SpokePoolVerifier } from "../../../../contracts/SpokePoolVerifier.sol";
import { SpokePoolV3Periphery, SpokePoolPeripheryProxy } from "../../../../contracts/SpokePoolV3Periphery.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolV3PeripheryInterface } from "../../../../contracts/interfaces/SpokePoolV3PeripheryInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";
import { MockPermit2, Permit2EIP712, SignatureVerification } from "../../../../contracts/test/MockPermit2.sol";
import { PeripherySigningLib } from "../../../../contracts/libraries/PeripherySigningLib.sol";
import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract Exchange {
    IPermit2 permit2;

    constructor(IPermit2 _permit2) {
        permit2 = _permit2;
    }

    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        bool usePermit2
    ) external {
        if (tokenIn.balanceOf(address(this)) >= amountIn) {
            tokenIn.transfer(address(1), amountIn);
            require(tokenOut.transfer(msg.sender, amountOutMin));
            return;
        }
        // The periphery contract should call the exchange, which should call permit2. Permit2 should call the periphery contract, and
        // should allow the exchange to take tokens away from the periphery.
        if (usePermit2) {
            permit2.transferFrom(msg.sender, address(this), uint160(amountIn), address(tokenIn));
            tokenOut.transfer(msg.sender, amountOutMin);
            return;
        }
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn));
        require(tokenOut.transfer(msg.sender, amountOutMin));
    }
}

// Utility contract which lets us perform external calls to an internal library.
contract HashUtils {
    function hashDepositData(SpokePoolV3PeripheryInterface.DepositData calldata depositData)
        external
        pure
        returns (bytes32)
    {
        return PeripherySigningLib.hashDepositData(depositData);
    }

    function hashSwapAndDepositData(SpokePoolV3Periphery.SwapAndDepositData calldata swapAndDepositData)
        external
        pure
        returns (bytes32)
    {
        return PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData);
    }
}

contract SpokePoolPeripheryTest is Test {
    Ethereum_SpokePool ethereumSpokePool;
    HashUtils hashUtils;
    SpokePoolV3Periphery spokePoolPeriphery;
    SpokePoolPeripheryProxy proxy;
    Exchange dex;
    Exchange cex;
    IPermit2 permit2;

    WETH9Interface mockWETH;
    MockERC20 mockERC20;

    address depositor;
    address owner;
    address recipient;
    address relayer;

    uint256 destinationChainId = 10;
    uint256 mintAmount = 10**22;
    uint256 submissionFeeAmount = 1;
    uint256 depositAmount = 5 * (10**18);
    uint256 depositAmountWithSubmissionFee = depositAmount + submissionFeeAmount;
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
        cex = new Exchange(permit2);

        vm.startPrank(owner);
        spokePoolPeriphery = new SpokePoolV3Periphery();
        domainSeparator = Permit2EIP712(address(permit2)).DOMAIN_SEPARATOR();
        proxy = new SpokePoolPeripheryProxy();
        proxy.initialize(spokePoolPeriphery);
        Ethereum_SpokePool implementation = new Ethereum_SpokePool(
            address(mockWETH),
            fillDeadlineBuffer,
            fillDeadlineBuffer
        );
        address spokePoolProxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(Ethereum_SpokePool.initialize, (0, owner)))
        );
        ethereumSpokePool = Ethereum_SpokePool(payable(spokePoolProxy));
        ethereumSpokePool.setEnableRoute(address(mockWETH), destinationChainId, true);
        ethereumSpokePool.setEnableRoute(address(mockERC20), destinationChainId, true);
        spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, address(proxy), permit2);
        vm.stopPrank();

        deal(depositor, mintAmountWithSubmissionFee);
        deal(address(mockERC20), depositor, mintAmountWithSubmissionFee, true);
        deal(address(mockERC20), address(dex), depositAmount, true);
        vm.startPrank(depositor);
        mockWETH.deposit{ value: mintAmountWithSubmissionFee }();
        mockERC20.approve(address(proxy), mintAmountWithSubmissionFee);
        IERC20(address(mockWETH)).approve(address(proxy), mintAmountWithSubmissionFee);

        // Approve permit2
        IERC20(address(mockWETH)).approve(address(permit2), mintAmountWithSubmissionFee * 10);
        vm.stopPrank();
    }

    function testInitializePeriphery() public {
        SpokePoolV3Periphery _spokePoolPeriphery = new SpokePoolV3Periphery();
        _spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, address(proxy), permit2);
        assertEq(address(_spokePoolPeriphery.spokePool()), address(ethereumSpokePool));
        assertEq(address(_spokePoolPeriphery.wrappedNativeToken()), address(mockWETH));
        assertEq(address(_spokePoolPeriphery.proxy()), address(proxy));
        assertEq(address(_spokePoolPeriphery.permit2()), address(permit2));
        vm.expectRevert(SpokePoolV3Periphery.ContractInitialized.selector);
        _spokePoolPeriphery.initialize(V3SpokePoolInterface(ethereumSpokePool), mockWETH, address(proxy), permit2);
    }

    function testInitializeProxy() public {
        SpokePoolPeripheryProxy _proxy = new SpokePoolPeripheryProxy();
        _proxy.initialize(spokePoolPeriphery);
        assertEq(address(_proxy.spokePoolPeriphery()), address(spokePoolPeriphery));
        vm.expectRevert(SpokePoolPeripheryProxy.ContractInitialized.selector);
        _proxy.initialize(spokePoolPeriphery);
    }

    /**
     * Approval based flows
     */
    function testSwapAndBridge() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        proxy.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolV3PeripheryInterface.TransferType.Approval,
                address(mockERC20),
                depositAmount,
                depositor
            )
        );
        vm.stopPrank();
    }

    function testSwapAndBridgePermitTransferType() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        proxy.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
                address(mockERC20),
                depositAmount,
                depositor
            )
        );
        vm.stopPrank();
    }

    function testSwapAndBridgeTransferTransferType() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        proxy.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolV3PeripheryInterface.TransferType.Transfer,
                address(mockERC20),
                depositAmount,
                depositor
            )
        );
        vm.stopPrank();
    }

    /**
     * Value based flows
     */
    function testSwapAndBridgeNoValueNoProxy() public {
        // Cannot call swapAndBridge with no value directly.
        vm.startPrank(depositor);
        vm.expectRevert(SpokePoolV3Periphery.NotProxy.selector);
        spokePoolPeriphery.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolV3PeripheryInterface.TransferType.Approval,
                address(mockERC20),
                depositAmount,
                depositor
            )
        );

        vm.stopPrank();
    }

    function testSwapAndBridgeWithValue() public {
        // Unlike previous test, this one calls the spokePoolPeriphery directly rather than through the proxy
        // because there is no approval required to be set on the periphery.
        deal(depositor, mintAmount);

        // Should emit expected deposit event
        vm.startPrank(depositor);

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge{ value: mintAmount }(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolV3PeripheryInterface.TransferType.Approval,
                address(mockERC20),
                depositAmount,
                depositor
            )
        );
        vm.stopPrank();
    }

    function testDepositWithValue() public {
        // Unlike previous test, this one calls the spokePoolPeriphery directly rather than through the proxy
        // because there is no approval required to be set on the periphery.
        deal(depositor, mintAmount);

        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockWETH),
            address(0),
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.deposit{ value: mintAmount }(
            depositor, // recipient
            address(mockWETH), // inputToken
            mintAmount,
            mintAmount,
            destinationChainId,
            address(0), // exclusiveRelayer
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testDepositNoValueNoProxy() public {
        // Cannot call deposit with no value directly.
        vm.startPrank(depositor);
        vm.expectRevert(SpokePoolV3Periphery.InvalidMsgValue.selector);
        spokePoolPeriphery.deposit(
            depositor, // recipient
            address(mockWETH), // inputToken
            mintAmount,
            mintAmount,
            destinationChainId,
            address(0), // exclusiveRelayer
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            new bytes(0)
        );

        vm.stopPrank();
    }

    /**
     * Permit (2612) based flows
     */
    function testPermitDepositValidWitness() public {
        SpokePoolV3PeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

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
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.depositWithPermit(
            depositor, // signatureOwner
            depositData,
            block.timestamp, // deadline
            signature, // permitSignature
            depositDataSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testPermitSwapAndBridgeValidWitness() public {
        // We need to deal the exchange some WETH in this test since we swap a permit ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor
        );

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
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the swap and deposit data signature.
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                spokePoolPeriphery.domainSeparator(),
                hashUtils.hashSwapAndDepositData(swapAndDepositData)
            )
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory swapAndDepositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockWETH),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor, // signatureOwner
            swapAndDepositData,
            block.timestamp, // deadline
            signature, // permitSignature
            swapAndDepositDataSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testPermitSwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);
        // We need to deal the exchange some WETH in this test since we swap a permit ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor
        );

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
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the swap and deposit data signature.
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                spokePoolPeriphery.domainSeparator(),
                hashUtils.hashSwapAndDepositData(swapAndDepositData)
            )
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory swapAndDepositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Make a swapAndDepositStruct which is different from the one the depositor signed off on. For example, make one where we set somebody else as the recipient/depositor.
        SpokePoolV3PeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando
        );

        // Should emit expected deposit event
        vm.expectRevert(SpokePoolV3Periphery.InvalidSignature.selector);
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor, // signatureOwner
            invalidSwapAndDepositData,
            block.timestamp, // deadline
            signature, // permitSignature
            swapAndDepositDataSignature
        );
    }

    /**
     * Transfer with authorization based flows
     */
    function testTransferWithAuthDepositValidWitness() public {
        SpokePoolV3PeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

        bytes32 nonce = bytes32(block.prevrandao);

        // Get the transfer with auth signature.
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                depositor,
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                block.timestamp,
                block.timestamp,
                nonce
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.depositWithAuthorization(
            depositor, // signatureOwner
            depositData,
            block.timestamp, // valid before
            block.timestamp, // valid after
            nonce, // nonce
            signature, // receiveWithAuthSignature
            depositDataSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthSwapAndBridgeValidWitness() public {
        // We need to deal the exchange some WETH in this test since we swap a eip3009 ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor
        );

        bytes32 nonce = bytes32(block.prevrandao);

        // Get the transfer with auth signature.
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                depositor,
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                block.timestamp,
                block.timestamp,
                nonce
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the swap and deposit data signature.
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                spokePoolPeriphery.domainSeparator(),
                hashUtils.hashSwapAndDepositData(swapAndDepositData)
            )
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory swapAndDepositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockWETH),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithAuthorization(
            depositor, // signatureOwner
            swapAndDepositData,
            block.timestamp, // validAfter
            block.timestamp, // validBefore
            nonce, // nonce
            signature, // receiveWithAuthSignature
            swapAndDepositDataSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthSwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);
        // We need to deal the exchange some WETH in this test since we swap a eip3009 ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor
        );

        bytes32 nonce = bytes32(block.prevrandao);

        // Get the transfer with auth signature.
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                depositor,
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                block.timestamp,
                block.timestamp,
                nonce
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the swap and deposit data signature.
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                spokePoolPeriphery.domainSeparator(),
                hashUtils.hashSwapAndDepositData(swapAndDepositData)
            )
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory swapAndDepositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Make a swapAndDepositStruct which is different from the one the depositor signed off on. For example, make one where we set somebody else as the recipient/depositor.
        SpokePoolV3PeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando
        );

        // Should emit expected deposit event
        vm.expectRevert(SpokePoolV3Periphery.InvalidSignature.selector);
        spokePoolPeriphery.swapAndBridgeWithAuthorization(
            depositor, // signatureOwner
            invalidSwapAndDepositData,
            block.timestamp, // validAfter
            block.timestamp, // validBefore
            nonce, // nonce
            signature, // receiveWithAuthSignature
            swapAndDepositDataSignature
        );
    }

    /**
     * Permit2 based flows
     */
    function testPermit2DepositValidWitness() public {
        SpokePoolV3PeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );
        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        // Get the permit2 signature.
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
                        hashUtils.hashDepositData(depositData)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockWETH),
            address(0),
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.depositWithPermit2(
            depositor, // signatureOwner
            depositData,
            permit, // permit
            signature // permit2 signature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockWETH.balanceOf(relayer), submissionFeeAmount);
    }

    function testPermit2SwapAndBridgeValidWitness() public {
        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor
        );

        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        // Get the permit2 signature.
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
                        hashUtils.hashSwapAndDepositData(swapAndDepositData)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.V3FundsDeposited(
            address(mockERC20),
            address(0),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor,
            depositor,
            address(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithPermit2(
            depositor, // signatureOwner
            swapAndDepositData,
            permit,
            signature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockWETH.balanceOf(relayer), submissionFeeAmount);
    }

    function testPermit2SwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);
        SpokePoolV3PeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor
        );

        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        // Get the permit2 signature.
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
                        hashUtils.hashSwapAndDepositData(swapAndDepositData)
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Make a swapAndDepositStruct which is different from the one the depositor signed off on. For example, make one where we set somebody else as the recipient/depositor.
        SpokePoolV3PeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolV3PeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando
        );

        // Should emit expected deposit event
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        spokePoolPeriphery.swapAndBridgeWithPermit2(
            depositor, // signatureOwner
            invalidSwapAndDepositData,
            permit,
            signature
        );
    }

    /**
     * Helper functions
     */
    function _defaultDepositData(
        address _token,
        uint256 _amount,
        uint256 _feeAmount,
        address _feeRecipient,
        address _depositor
    ) internal view returns (SpokePoolV3Periphery.DepositData memory) {
        return
            SpokePoolV3PeripheryInterface.DepositData({
                submissionFees: SpokePoolV3PeripheryInterface.Fees({ amount: _feeAmount, recipient: _feeRecipient }),
                baseDepositData: SpokePoolV3PeripheryInterface.BaseDepositData({
                    inputToken: _token,
                    outputToken: address(0),
                    outputAmount: _amount,
                    depositor: _depositor,
                    recipient: _depositor,
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: address(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                inputAmount: _amount
            });
    }

    function _defaultSwapAndDepositData(
        address _swapToken,
        uint256 _swapAmount,
        uint256 _feeAmount,
        address _feeRecipient,
        Exchange _exchange,
        SpokePoolV3PeripheryInterface.TransferType _transferType,
        address _inputToken,
        uint256 _amount,
        address _depositor
    ) internal view returns (SpokePoolV3Periphery.SwapAndDepositData memory) {
        bool usePermit2 = _transferType == SpokePoolV3PeripheryInterface.TransferType.Permit2Approval;
        return
            SpokePoolV3PeripheryInterface.SwapAndDepositData({
                submissionFees: SpokePoolV3PeripheryInterface.Fees({ amount: _feeAmount, recipient: _feeRecipient }),
                depositData: SpokePoolV3PeripheryInterface.BaseDepositData({
                    inputToken: _inputToken,
                    outputToken: address(0),
                    outputAmount: _amount,
                    depositor: _depositor,
                    recipient: _depositor,
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: address(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: _swapToken,
                exchange: address(_exchange),
                transferType: _transferType,
                swapTokenAmount: _swapAmount, // swapTokenAmount
                minExpectedInputTokenAmount: _amount,
                routerCalldata: abi.encodeWithSelector(
                    _exchange.swap.selector,
                    IERC20(_swapToken),
                    IERC20(_inputToken),
                    _swapAmount,
                    _amount,
                    usePermit2
                )
            });
    }
}
