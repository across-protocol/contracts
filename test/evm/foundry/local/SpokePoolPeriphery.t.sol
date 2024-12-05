// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { SpokePoolVerifier } from "../../../../contracts/SpokePoolVerifier.sol";
import { SpokePoolV3Periphery, SpokePoolPeripheryProxy } from "../../../../contracts/SpokePoolV3Periphery.sol";
import { Ethereum_SpokePool } from "../../../../contracts/Ethereum_SpokePool.sol";
import { V3SpokePoolInterface } from "../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { WETH9 } from "../../../../contracts/external/WETH9.sol";
import { WETH9Interface } from "../../../../contracts/external/interfaces/WETH9Interface.sol";
import { IPermit2 } from "../../../../contracts/external/interfaces/IPermit2.sol";
import { MockPermit2 } from "../../../../contracts/test/MockPermit2.sol";
import { PeripherySigningLib } from "../../../../contracts/libraries/PeripherySigningLib.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Exchange {
    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external {
        require(tokenIn.transferFrom(msg.sender, address(this), amountIn));
        require(tokenOut.transfer(msg.sender, amountOutMin));
    }
}

// Utility contract which lets us perform external calls to an internal library.
contract HashUtils {
    function hashDepositData(PeripherySigningLib.DepositData calldata depositData) external pure returns (bytes32) {
        return PeripherySigningLib.hashDepositData(depositData);
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
    ERC20 mockERC20;

    address depositor;
    address owner;
    address recipient;

    uint256 destinationChainId = 10;
    uint256 mintAmount = 10**22;
    uint256 depositAmount = 5 * (10**18);
    uint32 fillDeadlineBuffer = 7200;
    uint256 privateKey = 0x12345678910;

    bytes32 domainSeparator;
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    string private constant PERMIT_TRANSFER_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";

    bytes32 private constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256(abi.encode(PeripherySigningLib.TOKEN_PERMISSIONS_TYPE));

    function setUp() public {
        dex = new Exchange();
        cex = new Exchange();
        hashUtils = new HashUtils();

        mockWETH = WETH9Interface(address(new WETH9()));
        mockERC20 = new ERC20("ERC20", "ERC20");

        depositor = vm.addr(privateKey);
        owner = vm.addr(2);
        recipient = vm.addr(3);
        permit2 = IPermit2(new MockPermit2());

        vm.startPrank(owner);
        spokePoolPeriphery = new SpokePoolV3Periphery();
        (, bytes memory unprocessedDomainSeparator) = address(permit2).staticcall(abi.encode("DOMAIN_SEPARATOR"));
        domainSeparator = bytes32(unprocessedDomainSeparator);
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

        deal(depositor, mintAmount);
        deal(address(mockERC20), depositor, mintAmount, true);
        deal(address(mockERC20), address(dex), depositAmount, true);
        vm.startPrank(depositor);
        mockWETH.deposit{ value: mintAmount }();
        mockERC20.approve(address(proxy), mintAmount);
        IERC20(address(mockWETH)).approve(address(proxy), mintAmount);
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
        assertEq(address(_proxy.SPOKE_POOL_PERIPHERY()), address(spokePoolPeriphery));
        vm.expectRevert(SpokePoolPeripheryProxy.ContractInitialized.selector);
        _proxy.initialize(spokePoolPeriphery);
    }

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
            PeripherySigningLib.SwapAndDepositData({
                depositData: PeripherySigningLib.BaseDepositData({
                    inputToken: address(mockERC20),
                    outputToken: address(0),
                    outputAmount: depositAmount,
                    depositor: depositor,
                    recipient: depositor,
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: address(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: address(mockWETH),
                exchange: address(dex),
                transferType: PeripherySigningLib.TransferType.Approval,
                swapTokenAmount: mintAmount, // swapTokenAmount
                minExpectedInputTokenAmount: depositAmount,
                routerCalldata: abi.encodeWithSelector(
                    dex.swap.selector,
                    IERC20(address(mockWETH)),
                    IERC20(mockERC20),
                    mintAmount,
                    depositAmount
                )
            })
        );
        vm.stopPrank();
    }

    function testSwapAndBridgeNoValueNoProxy() public {
        // Cannot call swapAndBridge with no value directly.
        vm.startPrank(depositor);
        vm.expectRevert(SpokePoolV3Periphery.NotProxy.selector);
        spokePoolPeriphery.swapAndBridge(
            PeripherySigningLib.SwapAndDepositData({
                depositData: PeripherySigningLib.BaseDepositData({
                    inputToken: address(mockERC20),
                    outputToken: address(0),
                    outputAmount: depositAmount,
                    depositor: depositor,
                    recipient: depositor,
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: address(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: address(mockWETH),
                exchange: address(dex),
                transferType: PeripherySigningLib.TransferType.Approval,
                swapTokenAmount: mintAmount, // swapTokenAmount
                minExpectedInputTokenAmount: depositAmount,
                routerCalldata: abi.encodeWithSelector(
                    dex.swap.selector,
                    IERC20(address(mockWETH)),
                    IERC20(mockERC20),
                    mintAmount,
                    depositAmount
                )
            })
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
            PeripherySigningLib.SwapAndDepositData({
                depositData: PeripherySigningLib.BaseDepositData({
                    inputToken: address(mockERC20),
                    outputToken: address(0),
                    outputAmount: depositAmount,
                    depositor: depositor,
                    recipient: depositor,
                    destinationChainId: destinationChainId,
                    exclusiveRelayer: address(0),
                    quoteTimestamp: uint32(block.timestamp),
                    fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                    exclusivityParameter: 0,
                    message: new bytes(0)
                }),
                swapToken: address(mockWETH),
                exchange: address(dex),
                transferType: PeripherySigningLib.TransferType.Approval,
                swapTokenAmount: mintAmount, // swapTokenAmount
                minExpectedInputTokenAmount: depositAmount,
                routerCalldata: abi.encodeWithSelector(
                    dex.swap.selector,
                    IERC20(address(mockWETH)),
                    IERC20(mockERC20),
                    mintAmount,
                    depositAmount
                )
            })
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

    function testPermit2DepositValidWitness() public {
        deal(depositor, mintAmount);
        // Approve permit2
        IERC20(address(mockWETH)).approve(address(permit2), mintAmount);

        PeripherySigningLib.DepositData memory depositData = PeripherySigningLib.DepositData({
            baseDepositData: PeripherySigningLib.BaseDepositData({
                inputToken: address(mockWETH),
                outputToken: address(0),
                outputAmount: mintAmount,
                depositor: depositor,
                recipient: depositor,
                destinationChainId: destinationChainId,
                exclusiveRelayer: address(0),
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp) + fillDeadlineBuffer,
                exclusivityParameter: 0,
                message: new bytes(0)
            }),
            inputAmount: mintAmount
        });

        // Signature transfer details
        IPermit2.PermitTransferFrom memory permit = IPermit2.PermitTransferFrom({
            permitted: IPermit2.TokenPermissions({ token: address(mockWETH), amount: mintAmount }),
            nonce: 0,
            deadline: block.timestamp + 100
        });

        bytes32 typehash = keccak256(
            abi.encodePacked(PERMIT_TRANSFER_TYPEHASH_STUB, PeripherySigningLib.EIP712_DEPOSIT_DATA_TYPE)
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
                        address(this),
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
        spokePoolPeriphery.depositWithPermit2(
            address(0xFeABe39e2109234DB5803077Cb76eE533020E520), // signatureOwner
            depositData,
            permit, // permit
            //transferDetails, // transferDetails
            signature // permit2 signature
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
}
