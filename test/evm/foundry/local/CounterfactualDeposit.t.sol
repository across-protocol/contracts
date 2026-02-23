// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit, CounterfactualDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { SpokePoolImmutables, SpokePoolDepositParams, SpokePoolExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CCTPDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { OFTDepositParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

// ─── Mocks ──────────────────────────────────────────────────────────────

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
            IERC20(address(uint160(uint256(inputToken)))).safeTransferFrom(msg.sender, address(this), inputAmount);
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

contract MockCCTPSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMaxFee;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        IERC20(address(uint160(uint256(quote.burnToken)))).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        lastMaxFee = quote.maxFee;
        callCount++;
    }
}

contract MockOFTSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint32 public lastSrcEid;
    uint32 public lastDstEid;

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
        lastAmount = quote.signedParams.amountLD;
        lastNonce = quote.signedParams.nonce;
        lastMsgValue = msg.value;
        lastSrcEid = quote.signedParams.srcEid;
        lastDstEid = quote.signedParams.dstEid;
        callCount++;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

contract CounterfactualDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public implementation;
    MockSpokePool public spokePool;
    MockCCTPSrcPeriphery public cctpPeriphery;
    MockOFTSrcPeriphery public oftPeriphery;
    MintableERC20 public token;
    address public weth;

    address public admin;
    address public user;
    address public relayer;
    uint256 public signerPrivateKey;
    address public signerAddr;

    uint32 constant CCTP_SOURCE_DOMAIN = 2;
    uint32 constant OFT_SRC_EID = 30110;

    CounterfactualDepositParams internal defaultParams;
    SpokePoolImmutables internal defaultSpokePoolRoute;
    CCTPDepositParams internal defaultCCTPRoute;
    OFTDepositParams internal defaultOFTRoute;

    // EIP-712 constants (must match contract — name inherited from CounterfactualDepositSpokePool)
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
        weth = makeAddr("weth");

        token = new MintableERC20("USDC", "USDC", 6);
        spokePool = new MockSpokePool();
        cctpPeriphery = new MockCCTPSrcPeriphery();
        oftPeriphery = new MockOFTSrcPeriphery();
        factory = new CounterfactualDepositFactory();

        implementation = new CounterfactualDeposit(
            address(spokePool),
            signerAddr,
            weth,
            address(cctpPeriphery),
            CCTP_SOURCE_DOMAIN,
            address(oftPeriphery),
            OFT_SRC_EID
        );

        token.mint(user, 10_000e6);

        defaultSpokePoolRoute = SpokePoolImmutables({
            depositParams: SpokePoolDepositParams({
                destinationChainId: 42161,
                inputToken: bytes32(uint256(uint160(address(token)))),
                outputToken: bytes32(uint256(uint160(address(token)))),
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                message: ""
            }),
            executionParams: SpokePoolExecutionParams({ stableExchangeRate: 1e18, maxFeeFixed: 1e6, maxFeeBps: 500 })
        });

        defaultCCTPRoute = CCTPDepositParams({
            destinationDomain: 3,
            mintRecipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            burnToken: bytes32(uint256(uint160(address(token)))),
            destinationCaller: bytes32(0),
            cctpMaxFeeBps: 100,
            minFinalityThreshold: 1,
            maxBpsToSponsor: 0,
            maxUserSlippageBps: 100,
            finalRecipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            finalToken: bytes32(uint256(uint160(address(token)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            actionData: ""
        });

        defaultOFTRoute = OFTDepositParams({
            dstEid: 30101,
            destinationHandler: bytes32(uint256(uint160(makeAddr("handler")))),
            token: address(token),
            maxOftFeeBps: 50,
            lzReceiveGasLimit: 200_000,
            lzComposeGasLimit: 200_000,
            maxBpsToSponsor: 0,
            maxUserSlippageBps: 100,
            finalRecipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            finalToken: bytes32(uint256(uint160(address(token)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            refundRecipient: relayer,
            actionData: ""
        });

        defaultParams = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 1e6,
            spokePoolRouteHash: keccak256(abi.encode(defaultSpokePoolRoute)),
            cctpRouteHash: keccak256(abi.encode(defaultCCTPRoute)),
            oftRouteHash: keccak256(abi.encode(defaultOFTRoute))
        });
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

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

    function _deployClone(bytes32 salt) internal returns (address) {
        return factory.deploy(address(implementation), _paramsHash(), salt);
    }

    function _fundClone(address clone, uint256 amount) internal {
        vm.prank(user);
        token.transfer(clone, amount);
    }

    // ─── Address Prediction ─────────────────────────────────────────────

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");
        address predicted = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        address deployed = factory.deploy(address(implementation), _paramsHash(), salt);
        assertEq(predicted, deployed);
    }

    // ─── SpokePool Execution ────────────────────────────────────────────

    function testSpokePoolDeployAndExecute() public {
        bytes32 salt = keccak256("sp-salt");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        _fundClone(depositAddr, inputAmount);

        bytes memory execData = abi.encodeCall(
            CounterfactualDeposit.executeSpokePoolDeposit,
            (
                defaultParams,
                defaultSpokePoolRoute,
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
        address deployed = factory.deployAndExecute(address(implementation), _paramsHash(), salt, execData);

        assertEq(deployed, depositAddr);
        assertEq(token.balanceOf(depositAddr), 0);
        assertEq(token.balanceOf(relayer), defaultParams.executionFee);
        assertEq(spokePool.lastInputAmount(), inputAmount - defaultParams.executionFee);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(depositAddr))));
    }

    function testSpokePoolInvalidSignatureReverts() public {
        bytes32 salt = keccak256("sp-bad-sig");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = _deployClone(salt);

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
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(depositAddr), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        _fundClone(depositAddr, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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

    function testSpokePoolExpiredSignatureReverts() public {
        bytes32 salt = keccak256("sp-expired");
        uint256 inputAmount = 100e6;
        uint32 signatureDeadline = uint32(block.timestamp) + 100;

        address depositAddr = _deployClone(salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            uint32(block.timestamp),
            uint32(block.timestamp) + 3600,
            signatureDeadline
        );

        _fundClone(depositAddr, inputAmount);
        vm.warp(block.timestamp + 101);

        vm.expectRevert(ICounterfactualDeposit.SignatureExpired.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            uint32(block.timestamp) + 3600,
            signatureDeadline,
            sig
        );
    }

    function testSpokePoolExcessiveFeeReverts() public {
        bytes32 salt = keccak256("sp-fee");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 92e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = _deployClone(salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.MaxFee.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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

    function testSpokePoolFeeAtMaxPasses() public {
        bytes32 salt = keccak256("sp-fee-ok");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 94e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = _deployClone(salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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
        assertEq(spokePool.callCount(), 1);
    }

    function testSpokePoolCrossCloneReplay() public {
        bytes32 salt1 = keccak256("clone-1");
        bytes32 salt2 = keccak256("clone-2");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address clone1 = _deployClone(salt1);
        address clone2 = _deployClone(salt2);

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

        _fundClone(clone1, inputAmount);
        token.mint(user, inputAmount);
        _fundClone(clone2, inputAmount);

        vm.prank(relayer);
        CounterfactualDeposit(payable(clone1)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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

        vm.expectRevert(ICounterfactualDeposit.InvalidSignature.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(clone2)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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

    // ─── SpokePool Native ETH ───────────────────────────────────────────

    function testSpokePoolNativeDeposit() public {
        SpokePoolImmutables memory nativeRoute = SpokePoolImmutables({
            depositParams: SpokePoolDepositParams({
                destinationChainId: 42161,
                inputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
                outputToken: bytes32(uint256(uint160(NATIVE_ASSET))),
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                message: ""
            }),
            executionParams: SpokePoolExecutionParams({
                stableExchangeRate: 1e18,
                maxFeeFixed: 0.01 ether,
                maxFeeBps: 500
            })
        });

        CounterfactualDepositParams memory nativeParams = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 0.01 ether,
            spokePoolRouteHash: keccak256(abi.encode(nativeRoute)),
            cctpRouteHash: bytes32(0),
            oftRouteHash: bytes32(0)
        });

        bytes32 salt = keccak256("native-salt");
        bytes32 paramsHash = keccak256(abi.encode(nativeParams));
        address depositAddr = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        uint256 inputAmount = 1 ether;
        uint256 outputAmount = 0.98 ether;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.deal(depositAddr, inputAmount);

        bytes memory execData = abi.encodeCall(
            CounterfactualDeposit.executeSpokePoolDeposit,
            (
                nativeParams,
                nativeRoute,
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
        factory.deployAndExecute(address(implementation), paramsHash, salt, execData);

        assertEq(depositAddr.balance, 0);
        assertEq(relayer.balance, nativeParams.executionFee);
        assertEq(spokePool.lastInputAmount(), inputAmount - nativeParams.executionFee);
        assertEq(spokePool.lastMsgValue(), inputAmount - nativeParams.executionFee);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(weth))));
    }

    // ─── CCTP Execution ─────────────────────────────────────────────────

    function testCCTPDeployAndExecute() public {
        bytes32 salt = keccak256("cctp-salt");
        uint256 amount = 100e6;

        address depositAddr = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        _fundClone(depositAddr, amount);

        bytes memory execData = abi.encodeCall(
            CounterfactualDeposit.executeCCTPDeposit,
            (defaultParams, defaultCCTPRoute, amount, relayer, keccak256("nonce"), block.timestamp + 3600, "sig")
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(implementation), _paramsHash(), salt, execData);

        assertEq(deployed, depositAddr);
        assertEq(token.balanceOf(depositAddr), 0);
        assertEq(token.balanceOf(relayer), defaultParams.executionFee);
        assertEq(cctpPeriphery.lastAmount(), amount - defaultParams.executionFee);
        assertEq(cctpPeriphery.callCount(), 1);
    }

    function testCCTPMaxFeeCalculation() public {
        bytes32 salt = keccak256("cctp-fee");
        uint256 amount = 100e6;
        uint256 depositAmount = amount - defaultParams.executionFee;

        address depositAddr = _deployClone(salt);
        _fundClone(depositAddr, amount);

        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeCCTPDeposit(
            defaultParams,
            defaultCCTPRoute,
            amount,
            relayer,
            keccak256("nonce"),
            block.timestamp + 3600,
            "sig"
        );

        assertEq(cctpPeriphery.lastMaxFee(), (depositAmount * 100) / 10_000);
    }

    // ─── OFT Execution ──────────────────────────────────────────────────

    function testOFTDeployAndExecute() public {
        bytes32 salt = keccak256("oft-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.01 ether;

        address depositAddr = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        _fundClone(depositAddr, amount);

        bytes memory execData = abi.encodeCall(
            CounterfactualDeposit.executeOFTDeposit,
            (defaultParams, defaultOFTRoute, amount, relayer, keccak256("nonce"), block.timestamp + 3600, "sig")
        );

        vm.deal(relayer, lzFee);
        vm.prank(relayer);
        address deployed = factory.deployAndExecute{ value: lzFee }(
            address(implementation),
            _paramsHash(),
            salt,
            execData
        );

        assertEq(deployed, depositAddr);
        assertEq(token.balanceOf(relayer), defaultParams.executionFee);
        assertEq(oftPeriphery.lastAmount(), amount - defaultParams.executionFee);
        assertEq(oftPeriphery.lastMsgValue(), lzFee);
        assertEq(oftPeriphery.lastSrcEid(), OFT_SRC_EID);
        assertEq(oftPeriphery.lastDstEid(), defaultOFTRoute.dstEid);
        assertEq(oftPeriphery.callCount(), 1);
    }

    // ─── Route Hash Verification ────────────────────────────────────────

    function testInvalidRouteHashReverts() public {
        bytes32 salt = keccak256("bad-route");
        uint256 inputAmount = 100e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = _deployClone(salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        SpokePoolImmutables memory wrongRoute = defaultSpokePoolRoute;
        wrongRoute.depositParams.destinationChainId = 999;

        vm.expectRevert(ICounterfactualDeposit.InvalidRouteHash.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            wrongRoute,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testDisabledRouteReverts() public {
        CounterfactualDepositParams memory params = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 1e6,
            spokePoolRouteHash: bytes32(0),
            cctpRouteHash: keccak256(abi.encode(defaultCCTPRoute)),
            oftRouteHash: keccak256(abi.encode(defaultOFTRoute))
        });
        bytes32 paramsHash = keccak256(abi.encode(params));
        bytes32 salt = keccak256("disabled-route");

        address depositAddr = factory.deploy(address(implementation), paramsHash, salt);

        uint256 inputAmount = 100e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        vm.expectRevert(ICounterfactualDeposit.RouteDisabled.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            params,
            defaultSpokePoolRoute,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    function testDisabledCCTPRouteReverts() public {
        CounterfactualDepositParams memory params = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 1e6,
            spokePoolRouteHash: keccak256(abi.encode(defaultSpokePoolRoute)),
            cctpRouteHash: bytes32(0),
            oftRouteHash: keccak256(abi.encode(defaultOFTRoute))
        });
        bytes32 paramsHash = keccak256(abi.encode(params));
        bytes32 salt = keccak256("disabled-cctp");

        address depositAddr = factory.deploy(address(implementation), paramsHash, salt);
        _fundClone(depositAddr, 100e6);

        vm.expectRevert(ICounterfactualDeposit.RouteDisabled.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeCCTPDeposit(
            params,
            defaultCCTPRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 3600,
            "sig"
        );
    }

    // ─── Params Hash Verification ───────────────────────────────────────

    function testInvalidParamsHashReverts() public {
        bytes32 salt = keccak256("bad-params");
        address depositAddr = _deployClone(salt);
        _fundClone(depositAddr, 100e6);

        CounterfactualDepositParams memory wrongParams = defaultParams;
        wrongParams.spokePoolRouteHash = bytes32(uint256(1));

        uint256 inputAmount = 100e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            wrongParams,
            defaultSpokePoolRoute,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );
    }

    // ─── Withdrawals ────────────────────────────────────────────────────

    function testUserWithdraw() public {
        bytes32 salt = keccak256("withdraw");
        address depositAddr = _deployClone(salt);
        _fundClone(depositAddr, 100e6);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(address(token), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddr).userWithdraw(abi.encode(defaultParams), address(token), user, 100e6);

        assertEq(token.balanceOf(user), 10_000e6, "User should have all tokens back");
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("admin-wd");
        address depositAddr = _deployClone(salt);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddr, 100e18);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddr).adminWithdraw(
            abi.encode(defaultParams),
            address(wrongToken),
            admin,
            100e18
        );
        assertEq(wrongToken.balanceOf(admin), 100e18);
    }

    function testAdminWithdrawToUser() public {
        bytes32 salt = keccak256("admin-to-user");
        address depositAddr = _deployClone(salt);
        _fundClone(depositAddr, 50e6);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddr).adminWithdrawToUser(abi.encode(defaultParams), address(token), 50e6);
        assertEq(token.balanceOf(user), 10_000e6, "Tokens should go to user");
    }

    function testWithdrawUnauthorizedReverts() public {
        bytes32 salt = keccak256("unauth-wd");
        address depositAddr = _deployClone(salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddr).userWithdraw(abi.encode(defaultParams), address(token), relayer, 100e6);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(user);
        ICounterfactualDeposit(depositAddr).adminWithdraw(abi.encode(defaultParams), address(token), user, 100e6);
    }

    function testNativeUserWithdraw() public {
        CounterfactualDepositParams memory nativeParams = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 0,
            spokePoolRouteHash: bytes32(0),
            cctpRouteHash: bytes32(0),
            oftRouteHash: bytes32(0)
        });

        bytes32 salt = keccak256("native-wd");
        bytes32 paramsHash = keccak256(abi.encode(nativeParams));
        address depositAddr = factory.deploy(address(implementation), paramsHash, salt);

        vm.deal(depositAddr, 1 ether);

        uint256 userBalBefore = user.balance;
        vm.prank(user);
        ICounterfactualDeposit(depositAddr).userWithdraw(abi.encode(nativeParams), NATIVE_ASSET, user, 1 ether);
        assertEq(user.balance - userBalBefore, 1 ether);
    }

    // ─── Multi-Method on Same Address ───────────────────────────────────

    function testSameAddressMultipleMethods() public {
        bytes32 salt = keccak256("multi-method");
        address depositAddr = _deployClone(salt);

        // Execute via SpokePool
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            defaultParams,
            defaultSpokePoolRoute,
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
        assertEq(spokePool.callCount(), 1);

        // Execute via CCTP on same clone
        token.mint(user, 100e6);
        _fundClone(depositAddr, 100e6);

        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeCCTPDeposit(
            defaultParams,
            defaultCCTPRoute,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 3600,
            "sig"
        );
        assertEq(cctpPeriphery.callCount(), 1);

        // Execute via OFT on same clone
        token.mint(user, 100e6);
        _fundClone(depositAddr, 100e6);

        vm.deal(relayer, 0.01 ether);
        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeOFTDeposit{ value: 0.01 ether }(
            defaultParams,
            defaultOFTRoute,
            100e6,
            relayer,
            keccak256("nonce2"),
            block.timestamp + 3600,
            "sig"
        );
        assertEq(oftPeriphery.callCount(), 1);
    }

    // ─── deployIfNeededAndExecute ───────────────────────────────────────

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("idempotent");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);

        bytes memory sig1 = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        bytes memory execData1 = abi.encodeCall(
            CounterfactualDeposit.executeSpokePoolDeposit,
            (
                defaultParams,
                defaultSpokePoolRoute,
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

        vm.prank(relayer);
        factory.deployIfNeededAndExecute(address(implementation), _paramsHash(), salt, execData1);
        assertEq(spokePool.callCount(), 1);

        // Second call — clone already deployed
        token.mint(user, inputAmount);
        _fundClone(depositAddr, inputAmount);

        bytes memory sig2 = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            outputAmount,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        bytes memory execData2 = abi.encodeCall(
            CounterfactualDeposit.executeSpokePoolDeposit,
            (
                defaultParams,
                defaultSpokePoolRoute,
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
        factory.deployIfNeededAndExecute(address(implementation), _paramsHash(), salt, execData2);
        assertEq(spokePool.callCount(), 2);
    }

    function testExecuteWithZeroExecutionFee() public {
        CounterfactualDepositParams memory params = CounterfactualDepositParams({
            userWithdrawAddress: user,
            adminWithdrawAddress: admin,
            executionFee: 0,
            spokePoolRouteHash: keccak256(abi.encode(defaultSpokePoolRoute)),
            cctpRouteHash: keccak256(abi.encode(defaultCCTPRoute)),
            oftRouteHash: keccak256(abi.encode(defaultOFTRoute))
        });
        bytes32 paramsHash = keccak256(abi.encode(params));
        bytes32 salt = keccak256("zero-fee");
        uint256 inputAmount = 100e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        address depositAddr = factory.deploy(address(implementation), paramsHash, salt);
        bytes memory sig = _signExecuteDeposit(
            depositAddr,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );
        _fundClone(depositAddr, inputAmount);

        vm.prank(relayer);
        CounterfactualDeposit(payable(depositAddr)).executeSpokePoolDeposit(
            params,
            defaultSpokePoolRoute,
            inputAmount,
            98e6,
            bytes32(0),
            0,
            relayer,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600,
            sig
        );

        assertEq(token.balanceOf(relayer), 0);
        assertEq(spokePool.lastInputAmount(), inputAmount);
    }
}
