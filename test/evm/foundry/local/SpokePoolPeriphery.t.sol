// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SpokePoolVerifier } from "../../../../contracts/periphery/SpokePoolVerifier.sol";
import { SpokePoolPeriphery, SwapProxy } from "../../../../contracts/periphery/SpokePoolPeriphery.sol";
import { Ethereum_SpokePool } from "../../../../contracts/spoke-pools/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { SpokePoolPeripheryInterface } from "../../../../contracts/interfaces/SpokePoolPeripheryInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";
import { MockPermit2, Permit2EIP712, SignatureVerification } from "../../../../contracts/test/MockPermit2.sol";
import { PeripherySigningLib } from "../../../../contracts/libraries/PeripherySigningLib.sol";
import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { Multicall3 } from "../../../../contracts/external/Multicall3.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import { IERC1271 } from "@openzeppelin/contracts-v4/interfaces/IERC1271.sol";
import { ECDSA } from "@openzeppelin/contracts-v4/utils/cryptography/ECDSA.sol";
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

    // Enhanced swap function that returns more tokens than the minimum
    function swapWithExtraOutput(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 extraOutputPercentage,
        bool usePermit2
    ) external {
        if (tokenIn.balanceOf(address(this)) >= amountIn) {
            tokenIn.transfer(address(1), amountIn);
            // Calculate the extra amount based on percentage (in basis points)
            uint256 actualOutputAmount = amountOutMin + ((amountOutMin * extraOutputPercentage) / 10000);
            require(tokenOut.transfer(msg.sender, actualOutputAmount));
            return;
        }

        // Acquire tokens from the sender
        if (usePermit2) {
            permit2.transferFrom(msg.sender, address(this), uint160(amountIn), address(tokenIn));
        } else {
            require(tokenIn.transferFrom(msg.sender, address(this), amountIn));
        }

        // Calculate the extra amount based on percentage (in basis points)
        uint256 actualOutput = amountOutMin + ((amountOutMin * extraOutputPercentage) / 10000);
        require(tokenOut.transfer(msg.sender, actualOutput));
    }
}

// Minimal EIP-1271 contract wallet used to test the bytes-signature ERC-3009 flows. It treats a
// pre-approved (hash, signature) pair as the only valid signature.
contract EIP1271Wallet is IERC1271 {
    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;

    mapping(bytes32 => bytes32) private approvedSignatures;

    function approve(bytes32 hash, bytes calldata signature) external {
        approvedSignatures[hash] = keccak256(signature);
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (approvedSignatures[hash] == keccak256(signature) && approvedSignatures[hash] != bytes32(0)) {
            return MAGIC_VALUE;
        }
        return 0xffffffff;
    }
}

// Minimal EIP-1271 contract wallet whose owner is fixed at deploy time and which validates a signature
// by ECDSA-recovering it and comparing against that owner. Used to exercise the ERC-6492 counterfactual
// flow: the wallet does not exist until its factory is invoked by the periphery's prepare step.
contract CounterfactualEIP1271Wallet is IERC1271 {
    using ECDSA for bytes32;

    bytes4 private constant MAGIC_VALUE = 0x1626ba7e;
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return hash.recover(signature) == owner ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}

// CREATE2 factory for CounterfactualEIP1271Wallet. The wallet address is deterministic in (owner, salt),
// so it can be funded and signed for before deployment — exactly the ERC-6492 use case. createWallet is
// idempotent (returns the existing wallet if already deployed), mirroring real smart-wallet factories
// such as Coinbase's and Safe's.
contract CounterfactualWalletFactory {
    function createWallet(address owner, bytes32 salt) external returns (address wallet) {
        wallet = getWalletAddress(owner, salt);
        if (wallet.code.length == 0) {
            wallet = address(new CounterfactualEIP1271Wallet{ salt: salt }(owner));
        }
    }

    function getWalletAddress(address owner, bytes32 salt) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(CounterfactualEIP1271Wallet).creationCode, abi.encode(owner))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}

// A prepare target that always reverts, used to prove the periphery tolerates a failing ERC-6492
// prepare call (the call is routed through Multicall3 with requireSuccess=false).
contract RevertingPreparer {
    function prepare() external pure {
        revert("RevertingPreparer: always reverts");
    }
}

// Utility contract which lets us perform external calls to an internal library.
contract HashUtils {
    function hashDepositData(
        SpokePoolPeripheryInterface.DepositData calldata depositData
    ) external pure returns (bytes32) {
        return PeripherySigningLib.hashDepositData(depositData);
    }

    function hashSwapAndDepositData(
        SpokePoolPeriphery.SwapAndDepositData calldata swapAndDepositData
    ) external pure returns (bytes32) {
        return PeripherySigningLib.hashSwapAndDepositData(swapAndDepositData);
    }
}

contract SpokePoolPeripheryTest is Test {
    using AddressToBytes32 for address;

    Ethereum_SpokePool ethereumSpokePool;
    HashUtils hashUtils;
    SpokePoolPeriphery spokePoolPeriphery;
    Exchange dex;
    Exchange cex;
    IPermit2 permit2;

    WETH9Interface mockWETH;
    MockERC20 mockERC20;
    Multicall3 multicall3;

    address depositor;
    address owner;
    address recipient;
    address relayer;

    uint256 destinationChainId = 10;
    uint256 mintAmount = 10 ** 22;
    uint256 submissionFeeAmount = 1;
    uint256 depositAmount = 5 * (10 ** 18);
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
        multicall3 = new Multicall3();

        depositor = vm.addr(privateKey);
        owner = vm.addr(2);
        recipient = vm.addr(3);
        relayer = vm.addr(4);
        permit2 = IPermit2(new MockPermit2());
        dex = new Exchange(permit2);
        cex = new Exchange(permit2);

        vm.startPrank(owner);
        spokePoolPeriphery = new SpokePoolPeriphery(permit2, address(multicall3));
        domainSeparator = Permit2EIP712(address(permit2)).DOMAIN_SEPARATOR();
        Ethereum_SpokePool implementation = new Ethereum_SpokePool(
            address(mockWETH),
            fillDeadlineBuffer,
            fillDeadlineBuffer
        );
        address spokePoolProxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeCall(Ethereum_SpokePool.initialize, (0, owner)))
        );
        ethereumSpokePool = Ethereum_SpokePool(payable(spokePoolProxy));
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

    function testPeripheryConstructor() public {
        SpokePoolPeriphery _spokePoolPeriphery = new SpokePoolPeriphery(permit2, address(multicall3));
        assertEq(address(_spokePoolPeriphery.permit2()), address(permit2));
        assertEq(address(_spokePoolPeriphery.multicall3()), address(multicall3));
    }

    /**
     * Approval based flows
     */
    function testSwapAndBridge() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolPeripheryInterface.TransferType.Approval,
                address(mockERC20),
                depositAmount,
                depositor,
                true,
                0
            )
        );
        vm.stopPrank();
    }

    function testSwapAndBridgeWithProportionalOutput() public {
        // Prepare test data
        uint256 extraOutputPercentage = 2000; // 20% extra output
        uint256 minExpectedAmount = depositAmount;
        uint256 actualReturnAmount = (depositAmount * 120) / 100;
        uint256 expectedAdjustedOutput = (depositAmount * 120) / 100;

        // Deal more tokens to the exchange to cover the extra output
        deal(address(mockERC20), address(dex), actualReturnAmount, true);

        // Create custom calldata for the swapWithExtraOutput function
        bytes memory customCalldata = abi.encodeWithSelector(
            dex.swapWithExtraOutput.selector,
            IERC20(address(mockWETH)),
            IERC20(address(mockERC20)),
            mintAmount,
            minExpectedAmount,
            extraOutputPercentage,
            false
        );

        // Prepare the swap and deposit data with proportional adjustment enabled
        SpokePoolPeripheryInterface.SwapAndDepositData memory swapData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            0,
            address(0),
            dex,
            SpokePoolPeripheryInterface.TransferType.Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            true,
            0 // Enable proportional adjustment
        );

        // Update the router calldata to use our custom swap function
        swapData.routerCalldata = customCalldata;

        // Should emit expected deposit event with proportionally adjusted output amount
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            actualReturnAmount,
            expectedAdjustedOutput, // This should be proportionally increased
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );

        spokePoolPeriphery.swapAndBridge(swapData);
        vm.stopPrank();
    }

    function testSwapAndBridgeWithoutProportionalOutput() public {
        // Prepare test data - same as the test with proportional adjustment
        uint256 extraOutputPercentage = 2000; // 20% extra output
        uint256 minExpectedAmount = depositAmount;
        uint256 actualReturnAmount = (depositAmount * 120) / 100;

        // Deal more tokens to the exchange to cover the extra output
        deal(address(mockERC20), address(dex), actualReturnAmount, true);

        // Create custom calldata for the swapWithExtraOutput function
        bytes memory customCalldata = abi.encodeWithSelector(
            dex.swapWithExtraOutput.selector,
            IERC20(address(mockWETH)),
            IERC20(address(mockERC20)),
            mintAmount,
            minExpectedAmount,
            extraOutputPercentage,
            false
        );

        // Prepare the swap and deposit data with proportional adjustment disabled
        SpokePoolPeripheryInterface.SwapAndDepositData memory swapData = _defaultSwapAndDepositData(
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
            0 // Disable proportional adjustment
        );

        // Update the router calldata to use our custom swap function
        swapData.routerCalldata = customCalldata;

        // Should emit expected deposit event with original output amount (not adjusted)
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            actualReturnAmount,
            depositAmount, // This should be the original amount, not adjusted
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );

        spokePoolPeriphery.swapAndBridge(swapData);
        vm.stopPrank();
    }

    function testSwapAndBridgePermitTransferType() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolPeripheryInterface.TransferType.Permit2Approval,
                address(mockERC20),
                depositAmount,
                depositor,
                true,
                0
            )
        );
        vm.stopPrank();
    }

    function testSwapAndBridgeTransferTransferType() public {
        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolPeripheryInterface.TransferType.Transfer,
                address(mockERC20),
                depositAmount,
                depositor,
                true,
                0
            )
        );
        vm.stopPrank();
    }

    /**
     * Value based flows
     */
    function testSwapAndBridgeWithValue() public {
        // This test calls swapAndBridge with native token value
        deal(depositor, mintAmount);

        // Should emit expected deposit event
        vm.startPrank(depositor);

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            0, // depositId
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridge{ value: mintAmount }(
            _defaultSwapAndDepositData(
                address(mockWETH),
                mintAmount,
                0,
                address(0),
                dex,
                SpokePoolPeripheryInterface.TransferType.Approval,
                address(mockERC20),
                depositAmount,
                depositor,
                true,
                0
            )
        );
        vm.stopPrank();
    }

    function testDepositWithValue() public {
        // This test calls deposit with native token value
        deal(depositor, mintAmount);

        // Cache values to avoid stack-too-deep
        bytes32 inputToken = address(mockWETH).toBytes32();
        bytes32 depositorBytes32 = depositor.toBytes32();
        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = quoteTimestamp + fillDeadlineBuffer;

        // Should emit expected deposit event
        vm.startPrank(depositor);
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            inputToken,
            inputToken,
            mintAmount,
            mintAmount,
            destinationChainId,
            0, // depositId
            quoteTimestamp,
            fillDeadline,
            0, // exclusivityDeadline
            depositorBytes32,
            depositorBytes32,
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.depositNative{ value: mintAmount }(
            address(ethereumSpokePool), // spokePool address
            depositor, // depositor
            depositorBytes32, // recipient
            address(mockWETH), // inputToken
            mintAmount,
            inputToken, // outputToken
            mintAmount,
            destinationChainId,
            bytes32(0), // exclusiveRelayer
            quoteTimestamp,
            fillDeadline,
            0,
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testDepositWrongValue() public {
        // Should revert when trying to call deposit with wrong msg.value amount
        deal(depositor, mintAmount + 1); // Give some ETH to send

        // Cache values to avoid stack-too-deep
        bytes32 outputToken = address(mockWETH).toBytes32();
        bytes32 depositorBytes32 = depositor.toBytes32();
        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = quoteTimestamp + fillDeadlineBuffer;

        vm.startPrank(depositor);
        vm.expectRevert(V3SpokePoolInterface.MsgValueDoesNotMatchInputAmount.selector);
        spokePoolPeriphery.depositNative{ value: 1 }(
            // Send 1 wei but expecting mintAmount
            address(ethereumSpokePool), // spokePool address
            depositor, // depositor
            depositorBytes32, // recipient
            address(mockWETH), // inputToken
            mintAmount, // This doesn't match msg.value of 1
            outputToken, // outputToken
            mintAmount,
            destinationChainId,
            bytes32(0), // exclusiveRelayer
            quoteTimestamp,
            fillDeadline,
            0,
            new bytes(0)
        );

        vm.stopPrank();
    }

    function testDepositWithNonContractSpokePool() public {
        // Should revert when trying to call deposit with a non-contract address as spokePool
        // Give the depositor some ETH for the transaction
        deal(depositor, 1 ether);
        vm.startPrank(depositor);

        // Use an EOA address (depositor) as a non-contract address for spokePool
        address nonContractAddress = depositor;

        // The call should revert when the spokePool is not a contract
        vm.expectRevert();
        spokePoolPeriphery.depositNative{ value: 1 wei }(
            nonContractAddress, // spokePool - this is not a contract
            depositor, // depositor
            depositor.toBytes32(), // recipient
            address(mockWETH), // inputToken
            1 wei, // inputAmount
            address(mockWETH).toBytes32(), // outputToken
            1 wei, // outputAmount
            destinationChainId,
            bytes32(0), // exclusiveRelayer
            uint32(block.timestamp), // quoteTimestamp
            uint32(block.timestamp) + fillDeadlineBuffer, // fillDeadline
            0, // exclusivityParameter
            new bytes(0) // message
        );

        vm.stopPrank();
    }

    /**
     * Permit (2612) based flows
     */
    function testPermitDepositValidWitness() public {
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
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

        // Calculate the expected depositId using the periphery's getDepositId function
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor, // authorizer
            spokePoolPeriphery.PERMIT_NONCE_IDENTIFIER(),
            depositData.nonce,
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
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

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            spokePoolPeriphery.permitNonces(depositor)
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

        // Calculate the expected depositId using the periphery's getDepositId function
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            swapAndDepositData.depositData.depositor,
            depositor, // authorizer
            spokePoolPeriphery.PERMIT_NONCE_IDENTIFIER(),
            swapAndDepositData.nonce,
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockWETH).toBytes32(),
            address(mockWETH).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
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

        uint256 validNonce = spokePoolPeriphery.permitNonces(depositor);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            validNonce
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
        SpokePoolPeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando,
            true,
            validNonce
        );

        // Should emit expected deposit event
        vm.expectRevert(PeripherySigningLib.InvalidSignature.selector);
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
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

        // Compute the witness that will be used as the ERC-3009 nonce.
        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );
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

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Calculate the expected depositId using the periphery's getDepositId function
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor, // authorizer
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.depositWithAuthorization(
            depositor, // signatureOwner
            depositData,
            block.timestamp, // validAfter
            block.timestamp, // validBefore
            signature // receiveWithAuthSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthSwapAndBridgeValidWitness() public {
        // We need to deal the exchange some WETH in this test since we swap a eip3009 ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            0
        );

        // Compute the witness that will be used as the ERC-3009 nonce.
        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(swapAndDepositData))
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

        // Calculate the expected depositId using the periphery's getDepositId function
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor, // authorizer
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockWETH).toBytes32(),
            address(mockWETH).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithAuthorization(
            depositor, // signatureOwner
            swapAndDepositData,
            block.timestamp, // validAfter
            block.timestamp, // validBefore
            signature // receiveWithAuthSignature
        );

        // Check that fee recipient receives expected amount
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthSwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);
        // We need to deal the exchange some WETH in this test since we swap a eip3009 ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            0
        );

        // Compute the witness that will be used as the ERC-3009 nonce.
        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(swapAndDepositData))
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

        // Make a swapAndDepositStruct which is different from the one the depositor signed off on. For example, make one where we set somebody else as the recipient/depositor.
        SpokePoolPeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando,
            true,
            0
        );

        // Should emit expected deposit event
        vm.expectRevert();
        spokePoolPeriphery.swapAndBridgeWithAuthorization(
            depositor, // signatureOwner
            invalidSwapAndDepositData,
            block.timestamp, // validAfter
            block.timestamp, // validBefore
            signature // receiveWithAuthSignature
        );
    }

    /**
     * Transfer with authorization (bytes-signature variant) flows.
     *
     * These mirror the v/r/s tests above but exercise the extended EIP-3009 entry points that
     * accept `bytes signature` directly, allowing both EOA and EIP-1271 contract signers.
     */
    function testTransferWithAuthBytesDepositValidWitness() public {
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );
        bytes memory signature = _signReceiveWithAuthorization(
            privateKey,
            depositor,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor,
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0),
            new bytes(0)
        );
        spokePoolPeriphery.depositWithAuthorizationBytes(
            depositor,
            depositData,
            block.timestamp,
            block.timestamp,
            signature
        );

        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthBytesSwapAndBridgeValidWitness() public {
        // Deal exchange WETH since we swap an ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            0
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(swapAndDepositData))
        );
        bytes memory signature = _signReceiveWithAuthorization(
            privateKey,
            depositor,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor,
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockWETH).toBytes32(),
            address(mockWETH).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0),
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithAuthorizationBytes(
            depositor,
            swapAndDepositData,
            block.timestamp,
            block.timestamp,
            signature
        );

        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthBytesSwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            0
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(swapAndDepositData))
        );
        bytes memory signature = _signReceiveWithAuthorization(
            privateKey,
            depositor,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        // Same signature, but a swapAndDepositData object the depositor never signed off on.
        SpokePoolPeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando,
            true,
            0
        );

        vm.expectRevert();
        spokePoolPeriphery.swapAndBridgeWithAuthorizationBytes(
            depositor,
            invalidSwapAndDepositData,
            block.timestamp,
            block.timestamp,
            signature
        );
    }

    function testTransferWithAuthBytesDepositEIP1271ContractSigner() public {
        // Deploy a contract wallet that recognises a single fixed signature payload as valid.
        // Fund the wallet so it can authorize a transfer to the periphery.
        EIP1271Wallet wallet = new EIP1271Wallet();
        deal(address(mockERC20), address(wallet), mintAmountWithSubmissionFee, true);

        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            address(wallet)
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                address(wallet),
                address(spokePoolPeriphery),
                mintAmountWithSubmissionFee,
                block.timestamp,
                block.timestamp,
                witness
            )
        );
        bytes32 sigHash = mockERC20.hashTypedData(structHash);

        // The wallet treats this exact arbitrary blob as a valid signature for `sigHash`.
        bytes memory contractSignature = hex"deadbeef";
        wallet.approve(sigHash, contractSignature);

        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            address(wallet),
            address(wallet),
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            address(wallet).toBytes32(),
            address(wallet).toBytes32(),
            bytes32(0),
            new bytes(0)
        );
        spokePoolPeriphery.depositWithAuthorizationBytes(
            address(wallet),
            depositData,
            block.timestamp,
            block.timestamp,
            contractSignature
        );

        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    /**
     * ERC-6492 counterfactual contract-wallet flows.
     *
     * The periphery is not the signature verifier (the token is); it only runs the wrapped factory
     * call to deploy the signer before the token's EIP-1271 verification. These tests prove that a
     * deposit/swap can be authorized by a contract wallet that does not yet exist on-chain.
     */
    function testTransferWithAuthBytesDepositERC6492CounterfactualWallet() public {
        uint256 walletOwnerKey = 0xB0B;
        address walletOwner = vm.addr(walletOwnerKey);
        bytes32 salt = keccak256("erc6492-deposit-wallet");

        CounterfactualWalletFactory factory = new CounterfactualWalletFactory();
        address wallet = factory.getWalletAddress(walletOwner, salt);

        // The signer is counterfactual: no code at its address yet.
        assertEq(wallet.code.length, 0);

        // Fund the not-yet-deployed wallet so it can authorize a transfer to the periphery.
        deal(address(mockERC20), wallet, mintAmountWithSubmissionFee, true);

        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            wallet
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );

        // The wallet owner EOA signs the ERC-3009 digest on behalf of the (from = wallet) signer.
        bytes memory innerSignature = _signReceiveWithAuthorization(
            walletOwnerKey,
            wallet,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        // Wrap with the ERC-6492 factory call that deploys the wallet.
        bytes memory wrappedSignature = _wrapERC6492(
            address(factory),
            abi.encodeCall(CounterfactualWalletFactory.createWallet, (walletOwner, salt)),
            innerSignature
        );

        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            wallet,
            wallet,
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            wallet.toBytes32(),
            wallet.toBytes32(),
            bytes32(0),
            new bytes(0)
        );
        spokePoolPeriphery.depositWithAuthorizationBytes(
            wallet,
            depositData,
            block.timestamp,
            block.timestamp,
            wrappedSignature
        );

        // The prepare step materialized the wallet and the deposit went through.
        assertGt(wallet.code.length, 0);
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthBytesSwapAndBridgeERC6492CounterfactualWallet() public {
        // Deal exchange WETH since we swap an ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        uint256 walletOwnerKey = 0xB0B;
        address walletOwner = vm.addr(walletOwnerKey);
        bytes32 salt = keccak256("erc6492-swap-wallet");

        CounterfactualWalletFactory factory = new CounterfactualWalletFactory();
        address wallet = factory.getWalletAddress(walletOwner, salt);
        assertEq(wallet.code.length, 0);

        deal(address(mockERC20), wallet, mintAmountWithSubmissionFee, true);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            wallet,
            true,
            0
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_AND_SWAP_WITNESS_IDENTIFIER(), abi.encode(swapAndDepositData))
        );

        bytes memory innerSignature = _signReceiveWithAuthorization(
            walletOwnerKey,
            wallet,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        bytes memory wrappedSignature = _wrapERC6492(
            address(factory),
            abi.encodeCall(CounterfactualWalletFactory.createWallet, (walletOwner, salt)),
            innerSignature
        );

        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            wallet,
            wallet,
            spokePoolPeriphery.AUTHORIZATION_NONCE_IDENTIFIER(),
            uint256(witness),
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockWETH).toBytes32(),
            address(mockWETH).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0,
            wallet.toBytes32(),
            wallet.toBytes32(),
            bytes32(0),
            new bytes(0)
        );
        spokePoolPeriphery.swapAndBridgeWithAuthorizationBytes(
            wallet,
            swapAndDepositData,
            block.timestamp,
            block.timestamp,
            wrappedSignature
        );

        assertGt(wallet.code.length, 0);
        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthBytesDepositERC6492AlreadyDeployedWallet() public {
        uint256 walletOwnerKey = 0xB0B;
        address walletOwner = vm.addr(walletOwnerKey);
        bytes32 salt = keccak256("erc6492-already-deployed-wallet");

        CounterfactualWalletFactory factory = new CounterfactualWalletFactory();
        address wallet = factory.getWalletAddress(walletOwner, salt);

        // Deploy the wallet up front. The embedded (idempotent) factory call then becomes a cheap noop.
        factory.createWallet(walletOwner, salt);
        assertGt(wallet.code.length, 0);

        deal(address(mockERC20), wallet, mintAmountWithSubmissionFee, true);

        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            wallet
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );

        bytes memory innerSignature = _signReceiveWithAuthorization(
            walletOwnerKey,
            wallet,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        // Still ERC-6492 wrapped even though the wallet already exists; the prepare call is a noop and
        // the token verifies against the deployed wallet.
        bytes memory wrappedSignature = _wrapERC6492(
            address(factory),
            abi.encodeCall(CounterfactualWalletFactory.createWallet, (walletOwner, salt)),
            innerSignature
        );

        spokePoolPeriphery.depositWithAuthorizationBytes(
            wallet,
            depositData,
            block.timestamp,
            block.timestamp,
            wrappedSignature
        );

        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function testTransferWithAuthBytesDepositERC6492FailedPrepareTolerated() public {
        uint256 walletOwnerKey = 0xB0B;
        address walletOwner = vm.addr(walletOwnerKey);
        bytes32 salt = keccak256("erc6492-failed-prepare-wallet");

        CounterfactualWalletFactory factory = new CounterfactualWalletFactory();
        address wallet = factory.getWalletAddress(walletOwner, salt);
        // Wallet is already deployed, so the signature can be verified even if the prepare call fails.
        factory.createWallet(walletOwner, salt);
        assertGt(wallet.code.length, 0);

        deal(address(mockERC20), wallet, mintAmountWithSubmissionFee, true);

        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            wallet
        );

        bytes32 witness = keccak256(
            abi.encodePacked(spokePoolPeriphery.BRIDGE_WITNESS_IDENTIFIER(), abi.encode(depositData))
        );

        bytes memory innerSignature = _signReceiveWithAuthorization(
            walletOwnerKey,
            wallet,
            address(spokePoolPeriphery),
            mintAmountWithSubmissionFee,
            block.timestamp,
            block.timestamp,
            witness
        );

        // Point the prepare call at a target that always reverts. Because it is routed through
        // Multicall3 with requireSuccess=false, the failure is swallowed and the deposit still succeeds.
        RevertingPreparer reverter = new RevertingPreparer();
        bytes memory wrappedSignature = _wrapERC6492(
            address(reverter),
            abi.encodeCall(RevertingPreparer.prepare, ()),
            innerSignature
        );

        spokePoolPeriphery.depositWithAuthorizationBytes(
            wallet,
            depositData,
            block.timestamp,
            block.timestamp,
            wrappedSignature
        );

        assertEq(mockERC20.balanceOf(relayer), submissionFeeAmount);
    }

    function _wrapERC6492(
        address factory,
        bytes memory factoryCalldata,
        bytes memory innerSignature
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                abi.encode(factory, factoryCalldata, innerSignature),
                bytes32(0x6492649264926492649264926492649264926492649264926492649264926492)
            );
    }

    function _signReceiveWithAuthorization(
        uint256 _privateKey,
        address _from,
        address _to,
        uint256 _value,
        uint256 _validAfter,
        uint256 _validBefore,
        bytes32 _nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                mockERC20.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
                _from,
                _to,
                _value,
                _validAfter,
                _validBefore,
                _nonce
            )
        );
        bytes32 msgHash = mockERC20.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    /**
     * Permit2 based flows
     */
    function testPermit2DepositValidWitness() public {
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
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

        // Calculate expected deposit ID
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            depositor,
            depositor, // authorizer
            spokePoolPeriphery.PERMIT2_NONCE_IDENTIFIER(),
            depositData.nonce,
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockWETH).toBytes32(),
            address(mockWETH).toBytes32(),
            mintAmount,
            mintAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
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
        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor,
            true,
            permit.nonce
        );

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

        // Calculate expected deposit ID
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            swapAndDepositData.depositData.depositor,
            depositor, // authorizer
            spokePoolPeriphery.PERMIT2_NONCE_IDENTIFIER(),
            swapAndDepositData.nonce,
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            depositAmount,
            depositAmount,
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
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

    function testPermit2SwapAndBridgeWithProportionalOutput() public {
        // Prepare test data
        uint256 extraOutputPercentage = 2000; // 20% extra output
        uint256 minExpectedAmount = depositAmount;
        uint256 actualReturnAmount = minExpectedAmount + ((minExpectedAmount * extraOutputPercentage) / 10000);
        uint256 expectedAdjustedOutput = (depositAmount * actualReturnAmount) / minExpectedAmount;

        // Deal more tokens to the exchange to cover the extra output
        deal(address(mockERC20), address(dex), actualReturnAmount, true);

        // Create custom calldata for the swapWithExtraOutput function
        bytes memory customCalldata = abi.encodeWithSelector(
            dex.swapWithExtraOutput.selector,
            IERC20(address(mockWETH)),
            IERC20(address(mockERC20)),
            mintAmount,
            minExpectedAmount,
            extraOutputPercentage,
            true // Use permit2
        );

        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 2, // Use a different nonce from previous test
            deadline: block.timestamp + 100
        });

        // Prepare the swap and deposit data with submission fee
        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            true,
            permit.nonce // Enable proportional adjustment
        );

        // Update the router calldata to use our custom swap function
        swapAndDepositData.routerCalldata = customCalldata;

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPE_STUB, PeripherySigningLib.EIP712_SWAP_AND_DEPOSIT_TYPE_STRING)
        );
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted));

        // Get the permit2 signature
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

        // Calculate expected deposit ID
        uint256 expectedDepositId = spokePoolPeriphery.getDepositId(
            swapAndDepositData.depositData.depositor,
            depositor, // authorizer
            spokePoolPeriphery.PERMIT2_NONCE_IDENTIFIER(),
            swapAndDepositData.nonce,
            V3SpokePoolInterface(address(ethereumSpokePool))
        );

        // Should emit expected deposit event with proportionally adjusted output amount
        vm.expectEmit(address(ethereumSpokePool));
        emit V3SpokePoolInterface.FundsDeposited(
            address(mockERC20).toBytes32(),
            address(mockERC20).toBytes32(),
            actualReturnAmount,
            expectedAdjustedOutput, // This should be proportionally increased
            destinationChainId,
            expectedDepositId,
            uint32(block.timestamp),
            uint32(block.timestamp) + fillDeadlineBuffer,
            0, // exclusivityDeadline
            depositor.toBytes32(),
            depositor.toBytes32(),
            bytes32(0), // exclusiveRelayer
            new bytes(0)
        );

        spokePoolPeriphery.swapAndBridgeWithPermit2(
            depositor, // signatureOwner
            swapAndDepositData,
            permit,
            signature
        );

        // Check that fee recipient receives expected amount
        // The relayer receives submission fee amount from each test that uses fees
        // In this case, we're running after testPermit2SwapAndBridgeValidWitness which gives 1 fee
        assertEq(mockWETH.balanceOf(relayer), submissionFeeAmount);
    }

    function testPermit2SwapAndBridgeInvalidWitness(address rando) public {
        vm.assume(rando != depositor);

        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmountWithSubmissionFee }),
            nonce: 1,
            deadline: block.timestamp + 100
        });

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Transfer,
            address(mockERC20),
            depositAmount,
            depositor,
            true,
            permit.nonce
        );

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
        SpokePoolPeripheryInterface.SwapAndDepositData memory invalidSwapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            rando,
            true,
            permit.nonce
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
     * Security tests
     */
    function testSwapAndBridgeBlocksPermit2AsExchange() public {
        // This test verifies that the fix prevents using permit2 as the exchange address
        // which would allow DoS attacks via invalidateNonces
        vm.startPrank(depositor);

        // Prepare the swap data first (this will call permitNonces)
        SpokePoolPeripheryInterface.SwapAndDepositData memory swapData = _defaultSwapAndDepositData(
            address(mockWETH),
            mintAmount,
            0,
            address(0),
            Exchange(address(permit2)), // Using permit2 as exchange should fail
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockERC20),
            depositAmount,
            depositor,
            true,
            0 // Regular swapAndBridge requires nonce 0
        );

        // Attempt to use permit2 as the exchange - this should fail with InvalidExchange
        vm.expectRevert(SwapProxy.InvalidExchange.selector);
        spokePoolPeriphery.swapAndBridge(swapData);
        vm.stopPrank();
    }

    /**
     * Test zero-address fee recipient convention
     */
    function testZeroAddressFeeRecipientUsesMessageSender() public {
        // Test with permit-based swap where fee recipient is zero address
        // A relayer (different EOA) submits the transaction, so they should receive the fee
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        // Get initial balances of both depositor and relayer
        uint256 initialDepositorBalance = mockERC20.balanceOf(depositor);
        uint256 initialRelayerBalance = mockERC20.balanceOf(relayer);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            address(0), // Zero address fee recipient
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            spokePoolPeriphery.permitNonces(depositor)
        );

        bytes32 nonce = 0;

        // Get the permit signature
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

        // Get the swap and deposit data signature
        bytes32 swapAndDepositMsgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                spokePoolPeriphery.domainSeparator(),
                hashUtils.hashSwapAndDepositData(swapAndDepositData)
            )
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, swapAndDepositMsgHash);
        bytes memory swapAndDepositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        vm.startPrank(relayer);
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor,
            swapAndDepositData,
            block.timestamp,
            signature,
            swapAndDepositDataSignature
        );
        vm.stopPrank();

        // Check that the depositor paid the full amount (mintAmount + submissionFeeAmount) for the swap
        uint256 finalDepositorBalance = mockERC20.balanceOf(depositor);
        uint256 depositorDecrease = initialDepositorBalance - finalDepositorBalance;
        assertEq(
            depositorDecrease,
            mintAmountWithSubmissionFee,
            "Depositor should pay full amount including submission fee"
        );

        // Check that the relayer (msg.sender) received the submission fee since recipient was zero address
        uint256 finalRelayerBalance = mockERC20.balanceOf(relayer);
        uint256 relayerIncrease = finalRelayerBalance - initialRelayerBalance;
        assertEq(
            relayerIncrease,
            submissionFeeAmount,
            "Relayer should receive submission fee when recipient is zero address"
        );
    }

    function testZeroAddressFeeRecipientWithDeposit() public {
        // Test with regular deposit where fee recipient is zero address
        // A relayer (different EOA) submits the transaction, so they should receive the fee
        uint256 initialDepositorBalance = mockERC20.balanceOf(depositor);
        uint256 initialRelayerBalance = mockERC20.balanceOf(relayer);

        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            address(0), // Zero address fee recipient
            depositor
        );

        bytes32 nonce = 0;

        // Get the permit signature
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

        // Get the deposit data signature
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        vm.startPrank(relayer);
        spokePoolPeriphery.depositWithPermit(depositor, depositData, block.timestamp, signature, depositDataSignature);
        vm.stopPrank();

        // Check that the depositor paid the full amount (mintAmount + submissionFeeAmount) for the deposit
        uint256 finalDepositorBalance = mockERC20.balanceOf(depositor);
        uint256 depositorDecrease = initialDepositorBalance - finalDepositorBalance;
        assertEq(
            depositorDecrease,
            mintAmountWithSubmissionFee,
            "Depositor should pay full amount including submission fee"
        );

        // Check that the relayer (transaction submitter) received the submission fee since recipient was zero address
        uint256 finalRelayerBalance = mockERC20.balanceOf(relayer);
        uint256 relayerIncrease = finalRelayerBalance - initialRelayerBalance;
        assertEq(
            relayerIncrease,
            submissionFeeAmount,
            "Relayer should receive submission fee when recipient is zero address"
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
    ) internal view returns (SpokePoolPeriphery.DepositData memory) {
        return
            SpokePoolPeripheryInterface.DepositData({
                submissionFees: SpokePoolPeripheryInterface.Fees({ amount: _feeAmount, recipient: _feeRecipient }),
                baseDepositData: SpokePoolPeripheryInterface.BaseDepositData({
                    inputToken: _token,
                    outputToken: _token.toBytes32(),
                    outputAmount: _amount,
                    depositor: _depositor,
                    recipient: _depositor.toBytes32(),
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: bytes32(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                inputAmount: _amount,
                spokePool: address(ethereumSpokePool),
                nonce: spokePoolPeriphery.permitNonces(_depositor)
            });
    }

    function testNonceInitiallyZero() public {
        assertEq(spokePoolPeriphery.permitNonces(depositor), 1);
    }

    function testNonceIncrementsAfterDepositWithPermit() public {
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

        // Check initial nonce
        uint256 initialNonce = spokePoolPeriphery.permitNonces(depositor);

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
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", mockERC20.hashTypedData(bytes32(0)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        spokePoolPeriphery.depositWithPermit(depositor, depositData, block.timestamp, signature, depositDataSignature);

        // Check that nonce was incremented
        assertEq(spokePoolPeriphery.permitNonces(depositor), initialNonce + 1);
    }

    function testDepositWithPermitInvalidNonce() public {
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            depositor
        );

        // Manually set an invalid nonce (current nonce is 0, we'll use 5)
        depositData.nonce = 5;

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
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", mockERC20.hashTypedData(bytes32(0)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // Should revert with InvalidNonce error
        vm.expectRevert(SpokePoolPeriphery.InvalidNonce.selector);
        spokePoolPeriphery.depositWithPermit(depositor, depositData, block.timestamp, signature, depositDataSignature);
    }

    function testSwapAndBridgeWithPermitInvalidNonce() public {
        // We need to deal the exchange some WETH in this test since we swap a permit ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            0
        );

        // Manually set an invalid nonce (current nonce is 0, we'll use 10)
        swapAndDepositData.nonce = 10;

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
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", mockERC20.hashTypedData(bytes32(0)), structHash));
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

        // Should revert with InvalidNonce error
        vm.expectRevert(SpokePoolPeriphery.InvalidNonce.selector);
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor,
            swapAndDepositData,
            block.timestamp,
            signature,
            swapAndDepositDataSignature
        );
    }

    function testDepositWithPermitReplayPrevention() public {
        // Execute a valid transaction first
        SpokePoolPeripheryInterface.DepositData memory depositData = _defaultDepositData(
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
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", mockERC20.hashTypedData(bytes32(0)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        bytes memory signature = bytes.concat(r, s, bytes1(v));

        // Get the deposit data signature.
        bytes32 depositMsgHash = keccak256(
            abi.encodePacked("\x19\x01", spokePoolPeriphery.domainSeparator(), hashUtils.hashDepositData(depositData))
        );
        (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(privateKey, depositMsgHash);
        bytes memory depositDataSignature = bytes.concat(_r, _s, bytes1(_v));

        // First transaction should succeed
        spokePoolPeriphery.depositWithPermit(depositor, depositData, block.timestamp, signature, depositDataSignature);

        // Give more tokens for second attempt
        deal(address(mockERC20), depositor, mintAmountWithSubmissionFee, true);
        vm.prank(depositor);
        mockERC20.approve(address(spokePoolPeriphery), mintAmountWithSubmissionFee);

        // Try to use the same depositData (with same nonce=0) again - should fail
        vm.expectRevert(SpokePoolPeriphery.InvalidNonce.selector);
        spokePoolPeriphery.depositWithPermit(
            depositor,
            depositData, // Same data with nonce=0, but user nonce is now 1
            block.timestamp,
            signature,
            depositDataSignature
        );
    }

    function testSwapAndBridgeWithPermitReplayPrevention() public {
        // We need to deal the exchange some WETH in this test since we swap a permit ERC20 to WETH.
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        SpokePoolPeripheryInterface.SwapAndDepositData memory swapAndDepositData = _defaultSwapAndDepositData(
            address(mockERC20),
            mintAmount,
            submissionFeeAmount,
            relayer,
            dex,
            SpokePoolPeripheryInterface.TransferType.Permit2Approval,
            address(mockWETH),
            depositAmount,
            depositor,
            true,
            spokePoolPeriphery.permitNonces(depositor) // Use proper nonce (will be 1 initially)
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
        bytes32 msgHash = keccak256(abi.encodePacked("\x19\x01", mockERC20.hashTypedData(bytes32(0)), structHash));
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

        // First transaction should succeed
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor,
            swapAndDepositData,
            block.timestamp,
            signature,
            swapAndDepositDataSignature
        );

        // Deal more tokens and WETH for second attempt
        deal(address(mockERC20), depositor, mintAmountWithSubmissionFee, true);
        vm.prank(depositor);
        mockERC20.approve(address(spokePoolPeriphery), mintAmountWithSubmissionFee);
        mockWETH.deposit{ value: depositAmount }();
        mockWETH.transfer(address(dex), depositAmount);

        // Try to use the same swapAndDepositData (with same nonce=1) again - should fail
        vm.expectRevert(SpokePoolPeriphery.InvalidNonce.selector);
        spokePoolPeriphery.swapAndBridgeWithPermit(
            depositor,
            swapAndDepositData, // Same data with nonce=1, but user nonce is now 2
            block.timestamp,
            signature,
            swapAndDepositDataSignature
        );
    }

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
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: bytes32(0),
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
                ),
                enableProportionalAdjustment: _enableProportionalAdjustment,
                spokePool: address(ethereumSpokePool),
                nonce: _nonce
            });
    }
}
