// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositGlobalConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositBase.sol";
import { CounterfactualDepositMultiBridgeModular } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositMultiBridgeModular.sol";
import { CounterfactualDepositModularCCTPModule, CCTPSubmitterParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositModularCCTPModule.sol";
import { CounterfactualDepositModularOFTModule, OFTSubmitterParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositModularOFTModule.sol";
import { CounterfactualDepositModularSpokePoolModule, SpokePoolSubmitterParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositModularSpokePoolModule.sol";
import { CCTPRoute, CCTPDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { OFTRoute, OFTDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { SpokePoolRoute, SpokePoolDepositParams, SpokePoolExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualDepositRouteModule } from "../../../../contracts/interfaces/ICounterfactualDepositRouteModule.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";

contract MockSponsoredCCTPSrcPeripheryModular {
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

contract MockSponsoredOFTSrcPeripheryModular {
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

contract MockSpokePoolModular {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    bytes32 public lastDepositor;
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
        lastInputAmount = inputAmount;
        lastOutputAmount = outputAmount;
    }
}

struct TransferUserParams {
    address token;
    address recipient;
}

struct TransferSubmitterParams {
    address caller;
    uint256 amount;
}

contract MockTransferRouteModule is ICounterfactualDepositRouteModule {
    using SafeERC20 for IERC20;

    error GuardrailViolation();

    function execute(bytes calldata guardrailParams, bytes calldata submitterParams) external payable {
        TransferUserParams memory user = abi.decode(guardrailParams, (TransferUserParams));
        TransferSubmitterParams memory submitter = abi.decode(submitterParams, (TransferSubmitterParams));

        if (submitter.caller != msg.sender) revert GuardrailViolation();
        IERC20(user.token).safeTransfer(user.recipient, submitter.amount);
    }
}

contract CounterfactualDepositMultiBridgeModularTest is Test {
    bytes32 internal constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("CFSpokePool");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    CounterfactualDepositFactory public factory;
    CounterfactualDepositMultiBridgeModular public implementation;
    CounterfactualDepositModularCCTPModule public cctpModule;
    CounterfactualDepositModularOFTModule public oftModule;
    CounterfactualDepositModularSpokePoolModule public spokePoolModule;
    MockTransferRouteModule public transferModule;

    MockSponsoredCCTPSrcPeripheryModular public cctpSrcPeriphery;
    MockSponsoredOFTSrcPeripheryModular public oftSrcPeriphery;
    MockSpokePoolModular public spokePool;
    MintableERC20 public token;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerKey;
    address public signer;
    address public weth;

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
        cctpSrcPeriphery = new MockSponsoredCCTPSrcPeripheryModular();
        oftSrcPeriphery = new MockSponsoredOFTSrcPeripheryModular(address(token));
        spokePool = new MockSpokePoolModular();

        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositMultiBridgeModular();
        cctpModule = new CounterfactualDepositModularCCTPModule(address(cctpSrcPeriphery), 0);
        oftModule = new CounterfactualDepositModularOFTModule(address(oftSrcPeriphery), 30101);
        spokePoolModule = new CounterfactualDepositModularSpokePoolModule(address(spokePool), signer, weth);
        transferModule = new MockTransferRouteModule();

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
                routesRoot: routesRoot,
                userWithdrawAddress: user,
                adminWithdrawAddress: admin
            });
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _routeLeaf(address moduleImplementation, bytes memory guardrailParams) internal pure returns (bytes32) {
        return keccak256(abi.encode(moduleImplementation, keccak256(guardrailParams)));
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

    function testPredictAddressAndExecuteCCTPModule() public {
        bytes memory guardrailParams = abi.encode(cctpRoute);
        bytes memory submitterParams = abi.encode(
            CCTPSubmitterParams({
                amount: 100e6,
                executionFeeRecipient: relayer,
                nonce: keccak256("nonce-cctp"),
                cctpDeadline: block.timestamp + 1 hours,
                signature: "sig"
            })
        );

        bytes32 root = _routeLeaf(address(cctpModule), guardrailParams);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(root);
        bytes32 paramsHash = keccak256(abi.encode(config));
        bytes32 salt = keccak256("salt-modular-cctp");
        address predicted = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        vm.prank(user);
        token.transfer(predicted, 100e6);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositMultiBridgeModular.execute,
            (config, address(cctpModule), guardrailParams, submitterParams, new bytes32[](0))
        );

        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(address(implementation), paramsHash, salt, executeCalldata);

        assertEq(deployed, predicted);
        assertEq(token.balanceOf(relayer), cctpRoute.executionFee);
        assertEq(cctpSrcPeriphery.lastAmount(), 100e6 - cctpRoute.executionFee);
        assertEq(cctpSrcPeriphery.callCount(), 1);
    }

    function testExecuteOFTModuleWithValue() public {
        bytes memory guardrailParams = abi.encode(oftRoute);
        bytes memory submitterParams = abi.encode(
            OFTSubmitterParams({
                amount: 100e6,
                executionFeeRecipient: relayer,
                nonce: keccak256("nonce-oft"),
                oftDeadline: block.timestamp + 1 hours,
                signature: "sig"
            })
        );

        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(address(oftModule), guardrailParams)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-oft")
        );

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute{ value: 0.05 ether }(
            config,
            address(oftModule),
            guardrailParams,
            submitterParams,
            new bytes32[](0)
        );

        assertEq(token.balanceOf(relayer), oftRoute.executionFee);
        assertEq(oftSrcPeriphery.lastAmount(), 100e6 - oftRoute.executionFee);
        assertEq(oftSrcPeriphery.lastMsgValue(), 0.05 ether);
        assertEq(oftSrcPeriphery.callCount(), 1);
    }

    function testExecuteSpokePoolModule() public {
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = quoteTimestamp + 1800;
        uint32 signatureDeadline = quoteTimestamp + 3600;
        bytes memory guardrailParams = abi.encode(spokePoolRoute);

        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(address(spokePoolModule), guardrailParams)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-spoke")
        );

        bytes memory sig = _signSpoke(
            depositAddress,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            signerKey
        );
        bytes memory submitterParams = abi.encode(
            SpokePoolSubmitterParams({
                inputAmount: inputAmount,
                outputAmount: outputAmount,
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                executionFeeRecipient: relayer,
                quoteTimestamp: quoteTimestamp,
                fillDeadline: fillDeadline,
                signatureDeadline: signatureDeadline,
                signature: sig
            })
        );

        vm.prank(user);
        token.transfer(depositAddress, inputAmount);

        vm.prank(relayer);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(spokePoolModule),
            guardrailParams,
            submitterParams,
            new bytes32[](0)
        );

        assertEq(token.balanceOf(relayer), spokePoolRoute.executionParams.executionFee);
        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(depositAddress))));
        assertEq(spokePool.lastInputAmount(), inputAmount - spokePoolRoute.executionParams.executionFee);
        assertEq(spokePool.lastOutputAmount(), outputAmount);
    }

    function testSingleAddressCanExecuteMultipleModules() public {
        bytes memory cctpGuardrails = abi.encode(cctpRoute);
        bytes memory cctpSubmitter = abi.encode(
            CCTPSubmitterParams({
                amount: 100e6,
                executionFeeRecipient: relayer,
                nonce: keccak256("nonce-multi-cctp"),
                cctpDeadline: block.timestamp + 1 hours,
                signature: "sig"
            })
        );

        address recipient = makeAddr("custom-module-recipient");
        TransferUserParams memory transferUser = TransferUserParams({ token: address(token), recipient: recipient });
        bytes memory transferGuardrails = abi.encode(transferUser);
        bytes memory transferSubmitter = abi.encode(TransferSubmitterParams({ caller: relayer, amount: 30e6 }));

        bytes32 cctpLeaf = _routeLeaf(address(cctpModule), cctpGuardrails);
        bytes32 transferLeaf = _routeLeaf(address(transferModule), transferGuardrails);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(_hashPair(cctpLeaf, transferLeaf));
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-modular-multi")
        );

        vm.prank(user);
        token.transfer(depositAddress, 130e6);

        vm.prank(relayer);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(cctpModule),
            cctpGuardrails,
            cctpSubmitter,
            _singleProof(transferLeaf)
        );

        vm.prank(relayer);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(transferModule),
            transferGuardrails,
            transferSubmitter,
            _singleProof(cctpLeaf)
        );

        assertEq(cctpSrcPeriphery.callCount(), 1);
        assertEq(token.balanceOf(recipient), 30e6);
    }

    function testInvalidRouteProofReverts() public {
        bytes memory guardrailParams = abi.encode(cctpRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(address(cctpModule), guardrailParams)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-proof")
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidRouteProof.selector);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(oftModule),
            abi.encode(oftRoute),
            abi.encode(
                OFTSubmitterParams({
                    amount: 100e6,
                    executionFeeRecipient: relayer,
                    nonce: keccak256("nonce-proof"),
                    oftDeadline: block.timestamp + 1 hours,
                    signature: "sig"
                })
            ),
            new bytes32[](0)
        );
    }

    function testInvalidGuardrailCommitmentReverts() public {
        CCTPRoute memory provided = cctpRoute;
        provided.executionFee = cctpRoute.executionFee + 1;
        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(address(cctpModule), abi.encode(cctpRoute))
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-guardrail-mismatch")
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidRouteProof.selector);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(cctpModule),
            abi.encode(provided),
            abi.encode(
                CCTPSubmitterParams({
                    amount: 90e6,
                    executionFeeRecipient: relayer,
                    nonce: keccak256("nonce"),
                    cctpDeadline: block.timestamp + 1 hours,
                    signature: "sig"
                })
            ),
            new bytes32[](0)
        );
    }

    function testInvalidModuleImplementationReverts() public {
        address invalidImplementation = makeAddr("invalid-implementation");
        bytes memory guardrailParams = abi.encode(cctpRoute);
        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(invalidImplementation, guardrailParams)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-bad-impl")
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidModuleImplementation.selector);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            invalidImplementation,
            guardrailParams,
            bytes(""),
            new bytes32[](0)
        );
    }

    function testSupportsNewModulesWithoutChangingDispatcher() public {
        address recipient = makeAddr("recipient");
        bytes memory guardrailParams = abi.encode(TransferUserParams({ token: address(token), recipient: recipient }));
        bytes memory submitterParams = abi.encode(TransferSubmitterParams({ caller: relayer, amount: 25e6 }));
        CounterfactualDepositGlobalConfig memory config = _globalConfig(
            _routeLeaf(address(transferModule), guardrailParams)
        );
        address depositAddress = factory.deploy(
            address(implementation),
            keccak256(abi.encode(config)),
            keccak256("salt-custom-module")
        );

        vm.prank(user);
        token.transfer(depositAddress, 40e6);

        vm.prank(relayer);
        CounterfactualDepositMultiBridgeModular(payable(depositAddress)).execute(
            config,
            address(transferModule),
            guardrailParams,
            submitterParams,
            new bytes32[](0)
        );

        assertEq(token.balanceOf(recipient), 25e6);
    }

    function _singleProof(bytes32 sibling) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }
}
