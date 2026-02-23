// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositMultiBridgeSimple, CounterfactualDepositSimpleConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositMultiBridgeSimple.sol";
import { CCTPRoute, CCTPDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { OFTRoute, OFTDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { SpokePoolRoute, SpokePoolDepositParams, SpokePoolExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";

contract MockSponsoredCCTPSrcPeripherySimple {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    uint256 public callCount;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        address burnToken = address(uint160(uint256(quote.burnToken)));
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        callCount++;
    }
}

contract MockSponsoredOFTSrcPeripherySimple {
    using SafeERC20 for IERC20;

    address public immutable TOKEN;
    uint256 public lastAmount;
    uint256 public lastMsgValue;
    uint256 public callCount;

    constructor(address _token) {
        TOKEN = _token;
    }

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        lastAmount = quote.signedParams.amountLD;
        lastMsgValue = msg.value;
        callCount++;
    }
}

contract MockSpokePoolSimple {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    uint256 public lastInputAmount;

    function deposit(
        bytes32,
        bytes32,
        bytes32 inputToken,
        bytes32,
        uint256 inputAmount,
        uint256,
        uint256,
        bytes32,
        uint32,
        uint32,
        uint32,
        bytes calldata
    ) external payable {
        if (msg.value == 0) {
            IERC20(address(uint160(uint256(inputToken)))).safeTransferFrom(msg.sender, address(this), inputAmount);
        }
        lastInputAmount = inputAmount;
        callCount++;
    }
}

contract CounterfactualDepositMultiBridgeSimpleTest is Test {
    bytes32 internal constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("CFSpokePool");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    CounterfactualDepositFactory public factory;
    CounterfactualDepositMultiBridgeSimple public implementation;
    MockSponsoredCCTPSrcPeripherySimple public cctpSrcPeriphery;
    MockSponsoredOFTSrcPeripherySimple public oftSrcPeriphery;
    MockSpokePoolSimple public spokePool;
    MintableERC20 public token;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerKey;
    address public signer;

    CCTPRoute internal cctpRoute;
    OFTRoute internal oftRoute;
    SpokePoolRoute internal spokePoolRoute;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerKey = 0xA11CE;
        signer = vm.addr(signerKey);

        token = new MintableERC20("USDC", "USDC", 6);
        cctpSrcPeriphery = new MockSponsoredCCTPSrcPeripherySimple();
        oftSrcPeriphery = new MockSponsoredOFTSrcPeripherySimple(address(token));
        spokePool = new MockSpokePoolSimple();
        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositMultiBridgeSimple(
            address(cctpSrcPeriphery),
            0,
            address(oftSrcPeriphery),
            30101,
            address(spokePool),
            signer,
            makeAddr("weth")
        );

        cctpRoute = CCTPRoute({
            depositParams: CCTPDepositParams({
                destinationDomain: 3,
                mintRecipient: bytes32(uint256(uint160(makeAddr("dstPeriphery")))),
                burnToken: bytes32(uint256(uint160(address(token)))),
                destinationCaller: bytes32(uint256(uint160(makeAddr("bot")))),
                cctpMaxFeeBps: 100,
                minFinalityThreshold: 1000,
                maxBpsToSponsor: 500,
                maxUserSlippageBps: 50,
                finalRecipient: bytes32(uint256(uint160(makeAddr("finalRecipient")))),
                finalToken: bytes32(uint256(uint160(address(token)))),
                destinationDex: 0,
                accountCreationMode: 0,
                executionMode: 0,
                actionData: ""
            }),
            executionFee: 1e6
        });

        oftRoute = OFTRoute({
            depositParams: OFTDepositParams({
                dstEid: 30284,
                destinationHandler: bytes32(uint256(uint160(makeAddr("composer")))),
                token: address(token),
                maxOftFeeBps: 100,
                lzReceiveGasLimit: 200000,
                lzComposeGasLimit: 500000,
                maxBpsToSponsor: 500,
                maxUserSlippageBps: 50,
                finalRecipient: bytes32(uint256(uint160(makeAddr("finalRecipient")))),
                finalToken: bytes32(uint256(uint160(address(token)))),
                destinationDex: 0,
                accountCreationMode: 0,
                executionMode: 0,
                refundRecipient: makeAddr("refund"),
                actionData: ""
            }),
            executionFee: 1e6
        });

        spokePoolRoute = SpokePoolRoute({
            depositParams: SpokePoolDepositParams({
                destinationChainId: 42161,
                inputToken: bytes32(uint256(uint160(address(token)))),
                outputToken: bytes32(uint256(uint160(address(token)))),
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                message: ""
            }),
            executionParams: SpokePoolExecutionParams({
                stableExchangeRate: 1e18,
                maxFeeFixed: 1e6,
                maxFeeBps: 500,
                executionFee: 1e6
            })
        });

        token.mint(user, 10_000e6);
    }

    function _config(
        bytes32 cctpHash,
        bytes32 oftHash,
        bytes32 spokeHash
    ) internal view returns (CounterfactualDepositSimpleConfig memory) {
        return
            CounterfactualDepositSimpleConfig({
                commonParamsHash: keccak256("common-params"),
                cctpRouteHash: cctpHash,
                oftRouteHash: oftHash,
                spokePoolRouteHash: spokeHash,
                userWithdrawAddress: user,
                adminWithdrawAddress: admin
            });
    }

    function _spokeDomainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signSpoke(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        uint256 privateKey
    ) internal view returns (bytes memory) {
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _spokeDomainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testExecuteCCTPEnabled() public {
        CounterfactualDepositSimpleConfig memory config = _config(
            keccak256(abi.encode(cctpRoute)),
            bytes32(0),
            bytes32(0)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("cctp")
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeCCTP(
            config,
            cctpRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testExecuteCCTPDisabledReverts() public {
        CounterfactualDepositSimpleConfig memory config = _config(bytes32(0), bytes32(0), bytes32(0));
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("cctp-disabled")
        );

        vm.expectRevert(ICounterfactualDeposit.RouteDisabled.selector);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeCCTP(
            config,
            cctpRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testExecuteOFTHashMismatchReverts() public {
        CounterfactualDepositSimpleConfig memory config = _config(bytes32(0), keccak256("wrong"), bytes32(0));
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("oft-mismatch")
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidRouteHash.selector);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeOFT(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testExecuteOFTEnabled() public {
        CounterfactualDepositSimpleConfig memory config = _config(
            bytes32(0),
            keccak256(abi.encode(oftRoute)),
            bytes32(0)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("oft")
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeOFT{ value: 0.1 ether }(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(oftSrcPeriphery.callCount(), 1);
        assertEq(oftSrcPeriphery.lastMsgValue(), 0.1 ether);
    }

    function testExecuteSpokePoolEnabled() public {
        CounterfactualDepositSimpleConfig memory config = _config(
            bytes32(0),
            bytes32(0),
            keccak256(abi.encode(spokePoolRoute))
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("spoke")
        );

        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;
        bytes memory sig = _signSpoke(
            depositAddress,
            inputAmount,
            outputAmount,
            fillDeadline,
            signatureDeadline,
            signerKey
        );

        vm.prank(user);
        token.transfer(depositAddress, inputAmount);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeSpokePool(
            config,
            spokePoolRoute,
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

        assertEq(spokePool.callCount(), 1);
    }

    function testSingleAddressCanExecuteMultipleEnabledRoutes() public {
        CounterfactualDepositSimpleConfig memory config = _config(
            keccak256(abi.encode(cctpRoute)),
            keccak256(abi.encode(oftRoute)),
            bytes32(0)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("multi")
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeCCTP(
            config,
            cctpRoute,
            100e6,
            relayer,
            keccak256("nonce-cctp"),
            block.timestamp + 1 hours,
            "sig"
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeSimple(payable(depositAddress)).executeOFT{ value: 0.01 ether }(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce-oft"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(cctpSrcPeriphery.callCount(), 1);
        assertEq(oftSrcPeriphery.callCount(), 1);
    }

    function testWithdrawUsesSimpleConfig() public {
        CounterfactualDepositSimpleConfig memory config = _config(bytes32(0), bytes32(0), bytes32(0));
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("withdraw")
        );

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).userWithdraw(abi.encode(config), address(wrongToken), user, 25e18);
        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).adminWithdraw(abi.encode(config), address(wrongToken), admin, 75e18);

        assertEq(wrongToken.balanceOf(user), 25e18);
        assertEq(wrongToken.balanceOf(admin), 75e18);
    }
}
