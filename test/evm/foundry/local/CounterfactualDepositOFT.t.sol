// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositOFT, OFTDepositParams, OFTSubmitterData } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositOFT.sol";
import { WithdrawImplementation, WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { SponsoredOFTInterface } from "../../../../contracts/interfaces/SponsoredOFTInterface.sol";
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

    function deposit(SponsoredOFTInterface.Quote calldata quote, bytes calldata) external payable {
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
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositOFT public oftImpl;
    WithdrawImplementation public withdrawImpl;
    MockSponsoredOFTSrcPeriphery public srcPeriphery;
    MintableERC20 public token;
    Merkle public merkle;

    address public admin;
    address public user;
    address public relayer;

    uint32 public constant SRC_EID = 30101; // Ethereum LZ eid
    uint32 public constant DST_EID = 30284; // Example destination eid
    bytes32 public finalRecipient;

    OFTDepositParams internal defaultDepositParams;
    WithdrawParams internal withdrawParamsVal;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));

        token = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredOFTSrcPeriphery(address(token));
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        oftImpl = new CounterfactualDepositOFT(address(srcPeriphery), SRC_EID);
        withdrawImpl = new WithdrawImplementation();
        merkle = new Merkle();

        token.mint(user, 1000e6);

        defaultDepositParams = OFTDepositParams({
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
            actionData: "",
            executionFee: 1e6
        });

        withdrawParamsVal = WithdrawParams({ admin: admin, user: user });
    }

    // --- Merkle helpers ---

    function _leaf(address impl, bytes memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(impl, keccak256(params)));
    }

    /// @dev Build a 4-leaf merkle tree: [OFT deposit, withdraw, padding-a, padding-b].
    function _defaultLeaves() internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](4);
        leaves[0] = _leaf(address(oftImpl), abi.encode(defaultDepositParams));
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(withdrawParamsVal));
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");
    }

    function _merkleRoot() internal view returns (bytes32) {
        return merkle.getRoot(_defaultLeaves());
    }

    function _depositProof() internal view returns (bytes32[] memory) {
        return merkle.getProof(_defaultLeaves(), 0);
    }

    function _withdrawProof() internal view returns (bytes32[] memory) {
        return merkle.getProof(_defaultLeaves(), 1);
    }

    function _encodeDepositSubmitterData(
        uint256 amount,
        address executionFeeRecipient,
        bytes32 nonce,
        uint256 oftDeadline,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encode(OFTSubmitterData(amount, executionFeeRecipient, nonce, oftDeadline, signature));
    }

    function _encodeWithdrawSubmitterData(
        address tokenAddr,
        address to,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encode(tokenAddr, to, amount);
    }

    // --- Tests ---

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 root = _merkleRoot();

        address predicted = factory.predictDepositAddress(address(dispatcher), root, address(0), salt);
        address deployed = factory.deploy(address(dispatcher), root, address(0), salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        bytes32 root = _merkleRoot();
        address depositAddress = factory.predictDepositAddress(address(dispatcher), root, address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.expectEmit(true, true, true, true);
        emit CounterfactualDepositOFT.OFTDepositExecuted(amount, relayer, nonce, block.timestamp + 1 hours);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _encodeDepositSubmitterData(amount, relayer, nonce, block.timestamp + 1 hours, "sig"),
                _depositProof()
            )
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        address deployed = factory.deployAndExecute{ value: 0.1 ether }(
            address(dispatcher),
            root,
            address(0),
            salt,
            executeCalldata
        );

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(token.balanceOf(relayer), defaultDepositParams.executionFee, "Relayer should receive execution fee");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testMsgValueForwarded() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute{ value: lzFee }(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
            _depositProof()
        );

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded to SrcPeriphery");
    }

    function testQuoteParamsBuiltCorrectly() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
            _depositProof()
        );

        assertEq(srcPeriphery.lastSrcEid(), SRC_EID, "srcEid should match");
        assertEq(srcPeriphery.lastDstEid(), DST_EID, "dstEid should match");
        assertEq(
            srcPeriphery.lastDestinationHandler(),
            defaultDepositParams.destinationHandler,
            "destinationHandler should match"
        );
        assertEq(
            srcPeriphery.lastRefundRecipient(),
            defaultDepositParams.refundRecipient,
            "refundRecipient should match route immutable"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "amountLD should be net of execution fee");
    }

    function testExecuteOnExistingClone() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);

        // First deposit
        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _encodeDepositSubmitterData(100e6, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
            _depositProof()
        );

        // Second deposit
        vm.prank(user);
        token.transfer(depositAddress, 50e6);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(defaultDepositParams),
            _encodeDepositSubmitterData(50e6, relayer, keccak256("nonce-2"), block.timestamp + 1 hours, "sig"),
            _depositProof()
        );

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(token.balanceOf(depositAddress), 0, "All tokens should be deposited");
        assertEq(
            token.balanceOf(relayer),
            2 * defaultDepositParams.executionFee,
            "Relayer should receive fees from both deposits"
        );
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
                _depositProof()
            )
        );

        vm.prank(relayer);
        factory.execute(depositAddress, executeCalldata);

        assertEq(token.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(token.balanceOf(relayer), defaultDepositParams.executionFee, "Relayer should receive execution fee");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
    }

    function testExecuteViaFactoryForwardsMsgValue() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 lzFee = 0.05 ether;

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
                _depositProof()
            )
        );

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        factory.execute{ value: lzFee }(depositAddress, executeCalldata);

        assertEq(srcPeriphery.lastMsgValue(), lzFee, "msg.value should be forwarded through factory");
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(token), user, 100e6);

        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), user, 100e6),
            proof
        );

        assertEq(token.balanceOf(user), 1000e6, "User should have all tokens back");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), relayer, 100e6),
            proof
        );
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _withdrawProof();

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(wrongToken), admin, 100e18);

        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(wrongToken), admin, 100e18),
            proof
        );

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _withdrawProof();

        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), relayer, 100e6),
            proof
        );
    }

    function testExecuteWithZeroExecutionFee() public {
        OFTDepositParams memory zeroFeeParams = defaultDepositParams;
        zeroFeeParams.executionFee = 0;

        // Build a new merkle tree with the zero-fee deposit params.
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(oftImpl), abi.encode(zeroFeeParams));
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(withdrawParamsVal));
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(dispatcher), root, address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(zeroFeeParams),
            _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
            proof
        );

        assertEq(token.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(srcPeriphery.lastAmount(), amount, "Full amount should be deposited");
    }

    function testInvalidProofReverts() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _depositProof();

        vm.prank(user);
        token.transfer(depositAddress, 100e6);

        // Tamper with the deposit params so the leaf doesn't match the proof.
        OFTDepositParams memory wrongParams = defaultDepositParams;
        wrongParams.maxOftFeeBps = 200;

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(wrongParams),
            _encodeDepositSubmitterData(100e6, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
            proof
        );
    }

    function testInvalidProofWrongImplementation() public {
        bytes32 salt = keccak256("test-salt");

        address depositAddress = factory.deploy(address(dispatcher), _merkleRoot(), address(0), salt);
        bytes32[] memory proof = _withdrawProof();

        // Use the withdraw proof but with the OFT implementation address -- proof won't match.
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(oftImpl),
            abi.encode(withdrawParamsVal),
            _encodeWithdrawSubmitterData(address(token), user, 100e6),
            proof
        );
    }

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        bytes32 root = _merkleRoot();
        address depositAddress = factory.predictDepositAddress(address(dispatcher), root, address(0), salt);

        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, "sig"),
                _depositProof()
            )
        );

        // First call deploys and executes
        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(
            address(dispatcher),
            root,
            address(0),
            salt,
            executeCalldata
        );
        assertEq(deployed, depositAddress, "Should return predicted address");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "First deposit should execute");

        // Second call with clone already deployed -- should not revert
        vm.prank(user);
        token.transfer(depositAddress, amount);

        bytes memory executeCalldata2 = abi.encodeCall(
            CounterfactualDeposit.execute,
            (
                address(oftImpl),
                abi.encode(defaultDepositParams),
                _encodeDepositSubmitterData(amount, relayer, keccak256("nonce-2"), block.timestamp + 1 hours, "sig"),
                _depositProof()
            )
        );

        vm.prank(relayer);
        address deployed2 = factory.deployIfNeededAndExecute(
            address(dispatcher),
            root,
            address(0),
            salt,
            executeCalldata2
        );
        assertEq(deployed2, depositAddress, "Should return same address");
        assertEq(srcPeriphery.callCount(), 2, "Both deposits should execute");
    }
}
