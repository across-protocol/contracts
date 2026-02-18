// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositOFT, OFTImmutables, OFTDepositParams, OFTExecutionParams } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { Quote, SignedQuoteParams, UnsignedQuoteParams } from "../../../../contracts/periphery/mintburn/sponsored-oft/Structs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SponsoredOFTSrcPeriphery that simulates token transfer and records call data
 */
contract MockSponsoredOFTSrcPeriphery {
    using SafeERC20 for IERC20;

    address public immutable TOKEN;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMsgValue;
    uint256 public callCount;

    // Store the full quote for verification
    uint32 public lastSrcEid;
    uint32 public lastDstEid;
    bytes32 public lastDestinationHandler;
    address public lastRefundRecipient;

    constructor(address _token) {
        TOKEN = _token;
    }

    function deposit(Quote calldata quote, bytes calldata) external payable {
        // Pull tokens from caller (same as real SponsoredOFTSrcPeriphery)
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), quote.signedParams.amountLD);
        lastMsgValue = msg.value;
        lastAmount = quote.signedParams.amountLD;
        lastNonce = quote.signedParams.nonce;
        lastSrcEid = quote.signedParams.srcEid;
        lastDstEid = quote.signedParams.dstEid;
        lastDestinationHandler = quote.signedParams.destinationHandler;
        lastRefundRecipient = quote.unsignedParams.refundRecipient;
        callCount++;
    }

    receive() external payable {}
}

contract CounterfactualOFTDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDepositOFT public implementation;
    MockSponsoredOFTSrcPeriphery public srcPeriphery;
    MintableERC20 public token;

    address public admin;
    address public user;
    address public relayer;

    uint32 public constant SRC_EID = 30101; // Ethereum LZ eid
    uint32 public constant DST_EID = 30284; // Example destination eid
    bytes32 public finalRecipient;
    address public userWithdrawAddr;

    OFTImmutables internal defaultParams;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));
        userWithdrawAddr = user;

        token = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredOFTSrcPeriphery(address(token));
        factory = new CounterfactualDepositFactory();
        implementation = new CounterfactualDepositOFT(address(srcPeriphery), SRC_EID);

        token.mint(user, 1000e6);

        defaultParams = OFTImmutables({
            depositParams: OFTDepositParams({
                dstEid: DST_EID,
                destinationHandler: bytes32(uint256(uint160(makeAddr("composer")))),
                token: address(token),
                maxOftFeeBps: 100,
                lzReceiveGasLimit: 200000,
                lzComposeGasLimit: 500000,
                maxBpsToSponsor: 500,
                maxUserSlippageBps: 50,
                finalRecipient: finalRecipient,
                finalToken: bytes32(uint256(uint160(address(token)))),
                destinationDex: 0,
                accountCreationMode: 0,
                executionMode: 0,
                refundRecipient: makeAddr("refundRecipient"),
                actionData: ""
            }),
            executionParams: OFTExecutionParams({
                executionFee: 1e6,
                userWithdrawAddress: userWithdrawAddr,
                adminWithdrawAddress: admin
            })
        });
    }

    function _paramsHash() internal view returns (bytes32) {
        return keccak256(abi.encode(defaultParams));
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");

        address predicted = factory.predictDepositAddress(address(implementation), _paramsHash(), salt);
        address deployed = factory.deploy(address(implementation), _paramsHash(), salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultParams.executionParams.executionFee;

        bytes32 paramsHash = _paramsHash();
        address depositAddress = factory.predictDepositAddress(address(implementation), paramsHash, salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.CounterfactualDepositExecuted(
            expectedDeposit,
            nonce,
            relayer,
            defaultParams.executionParams.executionFee
        );

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositOFT.executeDeposit,
            (defaultParams, amount, relayer, nonce, block.timestamp + 1 hours, "sig")
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        address deployed = factory.deployAndExecute{ value: 0.1 ether }(
            address(implementation),
            paramsHash,
            salt,
            executeCalldata
        );

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            token.balanceOf(relayer),
            defaultParams.executionParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testMsgValueForwarded() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit{ value: lzFee }(
            defaultParams,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded to SrcPeriphery");
    }

    function testQuoteParamsBuiltCorrectly() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultParams.executionParams.executionFee;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit(
            defaultParams,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.lastSrcEid(), SRC_EID, "srcEid should match");
        assertEq(srcPeriphery.lastDstEid(), DST_EID, "dstEid should match");
        assertEq(
            srcPeriphery.lastDestinationHandler(),
            defaultParams.depositParams.destinationHandler,
            "destinationHandler should match"
        );
        assertEq(
            srcPeriphery.lastRefundRecipient(),
            defaultParams.depositParams.refundRecipient,
            "refundRecipient should match route immutable"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "amountLD should be net of execution fee");
    }

    function testExecuteOnExistingClone() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        // First deposit
        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit(
            defaultParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        // Second deposit
        vm.prank(user);
        token.transfer(depositAddress, 50e6);

        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit(
            defaultParams,
            50e6,
            relayer,
            keccak256("nonce-2"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(token.balanceOf(depositAddress), 0, "All tokens should be deposited");
        assertEq(
            token.balanceOf(relayer),
            2 * defaultParams.executionParams.executionFee,
            "Relayer should receive fees from both deposits"
        );
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultParams.executionParams.executionFee;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositOFT.executeDeposit,
            (defaultParams, amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig")
        );

        vm.prank(relayer);
        factory.execute(depositAddress, executeCalldata);

        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            token.balanceOf(relayer),
            defaultParams.executionParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
    }

    function testExecuteViaFactoryForwardsMsgValue() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDepositOFT.executeDeposit,
            (defaultParams, amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig")
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        factory.execute{ value: lzFee }(depositAddress, executeCalldata);

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded through factory");
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.AdminWithdraw(address(wrongToken), admin, 100e18);

        vm.prank(admin);
        CounterfactualDepositOFT(depositAddress).adminWithdraw(defaultParams, address(wrongToken), admin, 100e18);

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(user);
        CounterfactualDepositOFT(depositAddress).adminWithdraw(defaultParams, address(token), user, 100e6);
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDeposit.UserWithdraw(address(token), user, 100e6);

        vm.prank(user);
        CounterfactualDepositOFT(depositAddress).userWithdraw(defaultParams, address(token), user, 100e6);

        assertEq(token.balanceOf(user), 1000e6, "User should have all tokens back");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        vm.expectRevert(ICounterfactualDeposit.Unauthorized.selector);
        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).userWithdraw(defaultParams, address(token), relayer, 100e6);
    }

    function testExecuteWithZeroExecutionFee() public {
        OFTImmutables memory params = defaultParams;
        params.executionParams.executionFee = 0;
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(implementation), keccak256(abi.encode(params)), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit(
            params,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );

        assertEq(token.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(srcPeriphery.lastAmount(), amount, "Full amount should be deposited");
    }

    function testExecuteOnImplementationReverts() public {
        vm.expectRevert();
        implementation.executeDeposit(
            defaultParams,
            100e6,
            relayer,
            keccak256("nonce"),
            block.timestamp + 1 hours,
            "sig"
        );
    }

    function testInvalidParamsHashOnWithdraw() public {
        bytes32 salt = keccak256("test-salt");
        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        OFTImmutables memory wrongParams = defaultParams;
        wrongParams.depositParams.maxOftFeeBps = 200;

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(admin);
        CounterfactualDepositOFT(depositAddress).adminWithdraw(wrongParams, address(token), admin, 100e6);

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(user);
        CounterfactualDepositOFT(depositAddress).userWithdraw(wrongParams, address(token), user, 100e6);
    }

    function testInvalidParamsHash() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(implementation), _paramsHash(), salt);

        OFTImmutables memory wrongParams = defaultParams;
        wrongParams.depositParams.maxOftFeeBps = 200;

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.expectRevert(ICounterfactualDeposit.InvalidParamsHash.selector);
        vm.prank(relayer);
        CounterfactualDepositOFT(depositAddress).executeDeposit(
            wrongParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig"
        );
    }
}
