// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositMultiBridge } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositMultiBridge.sol";
import { CounterfactualDepositGlobalConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositBase.sol";
import { CCTPRoute, CCTPDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { OFTRoute, OFTDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { SpokePoolRoute, SpokePoolDepositParams, SpokePoolExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";

contract MockSponsoredCCTPSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public callCount;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        address burnToken = address(uint160(uint256(quote.burnToken)));
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        callCount++;
    }
}

contract MockSponsoredOFTSrcPeriphery {
    using SafeERC20 for IERC20;

    address public immutable TOKEN;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint256 public callCount;

    constructor(address _token) {
        TOKEN = _token;
    }

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        lastAmount = quote.signedParams.amountLD;
        lastNonce = quote.signedParams.nonce;
        lastMsgValue = msg.value;
        callCount++;
    }
}

contract MockSpokePool {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    bytes32 public lastDepositor;
    bytes32 public lastInputToken;
    uint256 public lastInputAmount;
    uint256 public lastOutputAmount;

    function deposit(
        bytes32 depositor,
        bytes32,
        bytes32 inputToken,
        bytes32,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256,
        bytes32,
        uint32,
        uint32,
        uint32,
        bytes calldata
    ) external payable {
        if (msg.value > 0) {
            require(msg.value == inputAmount, "msg.value mismatch");
        } else {
            IERC20(address(uint160(uint256(inputToken)))).safeTransferFrom(msg.sender, address(this), inputAmount);
        }

        callCount++;
        lastDepositor = depositor;
        lastInputToken = inputToken;
        lastInputAmount = inputAmount;
        lastOutputAmount = outputAmount;
    }
}

contract CounterfactualDepositMultiBridgeTest is Test {
    bytes32 internal constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("CounterfactualDepositMultiBridge");
    bytes32 internal constant VERSION_HASH = keccak256("v1.0.0");

    CounterfactualDepositFactory public factory;
    CounterfactualDepositMultiBridge public implementation;
    MockSponsoredCCTPSrcPeriphery public cctpSrcPeriphery;
    MockSponsoredOFTSrcPeriphery public oftSrcPeriphery;
    MockSpokePool public spokePool;
    MintableERC20 public token;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerKey;
    address public signer;
    address public weth;

    bytes32 public sharedParamsHash;

    CCTPRoute internal cctpRoute;
    OFTRoute internal oftRoute;
    SpokePoolRoute internal spokePoolRoute;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        signerKey = 0xA11CE;
        signer = vm.addr(signerKey);
        weth = makeAddr("weth");

        token = new MintableERC20("USDC", "USDC", 6);
        cctpSrcPeriphery = new MockSponsoredCCTPSrcPeriphery();
        oftSrcPeriphery = new MockSponsoredOFTSrcPeriphery(address(token));
        spokePool = new MockSpokePool();

        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositMultiBridge(
            address(cctpSrcPeriphery),
            0,
            address(oftSrcPeriphery),
            30101,
            address(spokePool),
            signer,
            weth
        );

        sharedParamsHash = keccak256("shared-params");

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

    function _globalConfig(bytes32 routesRoot) internal view returns (CounterfactualDepositGlobalConfig memory) {
        return
            CounterfactualDepositGlobalConfig({
                sharedParamsHash: sharedParamsHash,
                routesRoot: routesRoot,
                userWithdrawAddress: user,
                adminWithdrawAddress: admin
            });
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _spokeDomainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signSpoke(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes32 exclusiveRelayer,
        uint32 exclusivityDeadline,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        uint256 privateKey
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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _spokeDomainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testPredictAddressAndExecuteCCTP() public {
        bytes32 cctpLeaf = implementation.computeCCTPRouteLeaf(sharedParamsHash, cctpRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(cctpLeaf);
        bytes32 paramsHash = keccak256(abi.encode(config));
        bytes32 salt = keccak256("salt-cctp");

        address predicted = factory.predictDepositAddress(address(implementation), paramsHash, salt);
        vm.prank(user);
        token.transfer(predicted, 100e6);

        bytes32[] memory proof = new bytes32[](0);
        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositMultiBridge.executeCCTP,
            (config, cctpRoute, 100e6, relayer, keccak256("nonce-cctp"), block.timestamp + 1 hours, "sig", proof)
        );

        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(address(implementation), paramsHash, salt, executeCalldata);

        assertEq(deployed, predicted);
        assertEq(token.balanceOf(relayer), cctpRoute.executionFee);
        assertEq(cctpSrcPeriphery.lastAmount(), 100e6 - cctpRoute.executionFee);
        assertEq(cctpSrcPeriphery.callCount(), 1);
    }

    function testExecuteOFTWithProofAndValue() public {
        bytes32 oftLeaf = implementation.computeOFTRouteLeaf(sharedParamsHash, oftRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(oftLeaf);
        bytes32 salt = keccak256("salt-oft");
        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(config)), salt);

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        bytes32[] memory proof = new bytes32[](0);
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeOFT{ value: 0.05 ether }(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce-oft"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        assertEq(token.balanceOf(relayer), oftRoute.executionFee);
        assertEq(oftSrcPeriphery.lastAmount(), 100e6 - oftRoute.executionFee);
        assertEq(oftSrcPeriphery.lastMsgValue(), 0.05 ether);
        assertEq(oftSrcPeriphery.callCount(), 1);
    }

    function testExecuteSpokePoolWithProof() public {
        bytes32 spokeLeaf = implementation.computeSpokePoolRouteLeaf(sharedParamsHash, spokePoolRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(spokeLeaf);
        bytes32 salt = keccak256("salt-spoke");
        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(config)), salt);

        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;

        bytes memory sig = _signSpoke(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline,
            signerKey
        );

        vm.prank(user);
        token.transfer(depositAddress, inputAmount);

        bytes32[] memory proof = new bytes32[](0);
        vm.prank(relayer);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeSpokePool(
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
            sig,
            proof
        );

        assertEq(token.balanceOf(relayer), spokePoolRoute.executionParams.executionFee);
        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(depositAddress))));
        assertEq(spokePool.lastInputAmount(), inputAmount - spokePoolRoute.executionParams.executionFee);
        assertEq(spokePool.lastOutputAmount(), outputAmount);
    }

    function testSingleAddressCanExecuteMultipleRoutes() public {
        bytes32 cctpLeaf = implementation.computeCCTPRouteLeaf(sharedParamsHash, cctpRoute);
        bytes32 oftLeaf = implementation.computeOFTRouteLeaf(sharedParamsHash, oftRoute);
        bytes32 root = _hashPair(cctpLeaf, oftLeaf);

        CounterfactualDepositGlobalConfig memory config = _globalConfig(root);
        bytes32 salt = keccak256("salt-multi");
        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(config)), salt);

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        bytes32[] memory cctpProof = new bytes32[](1);
        cctpProof[0] = oftLeaf;
        vm.prank(relayer);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeCCTP(
            config,
            cctpRoute,
            100e6,
            relayer,
            keccak256("nonce-multi-cctp"),
            block.timestamp + 1 hours,
            "sig",
            cctpProof
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        bytes32[] memory oftProof = new bytes32[](1);
        oftProof[0] = cctpLeaf;
        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeOFT{ value: 0.01 ether }(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce-multi-oft"),
            block.timestamp + 1 hours,
            "sig",
            oftProof
        );

        assertEq(cctpSrcPeriphery.callCount(), 1);
        assertEq(oftSrcPeriphery.callCount(), 1);
    }

    function testInvalidRouteProofReverts() public {
        bytes32 cctpLeaf = implementation.computeCCTPRouteLeaf(sharedParamsHash, cctpRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(cctpLeaf);
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-proof")
        );

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(ICounterfactualDeposit.InvalidRouteProof.selector);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeOFT(
            config,
            oftRoute,
            100e6,
            relayer,
            keccak256("nonce-proof"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );
    }

    function testUserAndAdminWithdrawUseGlobalConfig() public {
        bytes32 cctpLeaf = implementation.computeCCTPRouteLeaf(sharedParamsHash, cctpRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(cctpLeaf);
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-wd")
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

    function testSpokePoolInvalidSignatureReverts() public {
        bytes32 spokeLeaf = implementation.computeSpokePoolRouteLeaf(sharedParamsHash, spokePoolRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(spokeLeaf);
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-badsig")
        );

        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;

        bytes memory badSig = _signSpoke(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            signatureDeadline,
            0xBEEF
        );

        vm.prank(user);
        token.transfer(depositAddress, inputAmount);

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDepositMultiBridge(payable(depositAddress)).executeSpokePool(
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
            badSig,
            proof
        );
    }
}
