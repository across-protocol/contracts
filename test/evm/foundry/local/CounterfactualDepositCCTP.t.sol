// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Merkle } from "murky/Merkle.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDepositCCTP, CCTPDepositParams, CCTPSubmitterData } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositCCTP.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { WithdrawImplementation, WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualDepositFactory } from "../../../../contracts/interfaces/ICounterfactualDepositFactory.sol";
import { SponsoredCCTPInterface } from "../../../../contracts/interfaces/SponsoredCCTPInterface.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock SponsoredCCTPSrcPeriphery that simulates the token transfer without CCTP
 */
contract MockSponsoredCCTPSrcPeriphery {
    using SafeERC20 for IERC20;

    uint256 public lastAmount;
    bytes32 public lastNonce;
    uint256 public lastMaxFee;
    uint256 public callCount;

    function depositForBurn(SponsoredCCTPInterface.SponsoredCCTPQuote memory quote, bytes memory) external {
        address burnToken = address(uint160(uint256(quote.burnToken)));
        IERC20(burnToken).safeTransferFrom(msg.sender, address(this), quote.amount);
        lastAmount = quote.amount;
        lastNonce = quote.nonce;
        lastMaxFee = quote.maxFee;
        callCount++;
    }
}

contract CounterfactualDepositTest is Test {
    CounterfactualDepositFactory public factory;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositCCTP public cctpImpl;
    WithdrawImplementation public withdrawImpl;
    MockSponsoredCCTPSrcPeriphery public srcPeriphery;
    MintableERC20 public burnToken;
    Merkle public merkle;

    address public admin;
    address public user;
    address public relayer;

    uint32 public constant SOURCE_DOMAIN = 0; // Ethereum
    uint32 public constant DESTINATION_DOMAIN = 3; // Hyperliquid
    bytes32 public finalRecipient;

    CCTPDepositParams internal defaultDepositParams;

    function setUp() public {
        admin = makeAddr("admin");
        user = makeAddr("user");
        relayer = makeAddr("relayer");
        finalRecipient = bytes32(uint256(uint160(makeAddr("finalRecipient"))));

        burnToken = new MintableERC20("USDC", "USDC", 6);

        srcPeriphery = new MockSponsoredCCTPSrcPeriphery();
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        cctpImpl = new CounterfactualDepositCCTP(address(srcPeriphery), SOURCE_DOMAIN);
        withdrawImpl = new WithdrawImplementation();
        merkle = new Merkle();

        burnToken.mint(user, 1000e6);

        defaultDepositParams = CCTPDepositParams({
            destinationDomain: DESTINATION_DOMAIN,
            mintRecipient: bytes32(uint256(uint160(makeAddr("dstPeriphery")))),
            burnToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationCaller: bytes32(uint256(uint160(makeAddr("bot")))),
            cctpMaxFeeBps: 100,
            minFinalityThreshold: 1000,
            maxBpsToSponsor: 500,
            maxUserSlippageBps: 50,
            finalRecipient: finalRecipient,
            finalToken: bytes32(uint256(uint160(address(burnToken)))),
            destinationDex: 0,
            accountCreationMode: 0,
            executionMode: 0,
            actionData: "",
            executionFee: 1e6
        });
    }

    // -- Helpers --

    /// @dev Build a merkle tree with a single CCTP deposit leaf and return (root, proof).
    function _depositOnlyTree(
        bytes memory depositParams
    ) internal view returns (bytes32 merkleRoot, bytes32[] memory proof) {
        // For a single-leaf tree, murky requires at least 2 leaves. Use the deposit leaf and a dummy.
        bytes32 depositLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(address(cctpImpl), keccak256(depositParams))))
        );
        bytes32 dummyLeaf = keccak256(bytes.concat(keccak256(abi.encode(address(0), keccak256("")))));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = depositLeaf;
        leaves[1] = dummyLeaf;

        merkleRoot = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
    }

    /// @dev Build a 2-leaf merkle tree with CCTP deposit + withdraw leaves.
    function _depositAndWithdrawTree(
        bytes memory depositParams,
        bytes memory withdrawParams
    ) internal view returns (bytes32 merkleRoot, bytes32[] memory depositProof, bytes32[] memory withdrawProof) {
        bytes32 depositLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(address(cctpImpl), keccak256(depositParams))))
        );
        bytes32 withdrawLeaf = keccak256(
            bytes.concat(keccak256(abi.encode(address(withdrawImpl), keccak256(withdrawParams))))
        );

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = depositLeaf;
        leaves[1] = withdrawLeaf;

        merkleRoot = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        withdrawProof = merkle.getProof(leaves, 1);
    }

    /// @dev Encode default deposit params.
    function _encodedDepositParams() internal view returns (bytes memory) {
        return abi.encode(defaultDepositParams);
    }

    /// @dev Build a default tree with deposit-only and return the merkle root.
    function _defaultMerkleRoot() internal view returns (bytes32) {
        (bytes32 root, ) = _depositOnlyTree(_encodedDepositParams());
        return root;
    }

    /// @dev Encode the execute calldata for a CCTP deposit through the dispatcher.
    function _executeCalldata(
        bytes memory depositParams,
        uint256 amount,
        address feeRecipient,
        bytes32 nonce,
        uint256 deadline,
        bytes memory sig,
        bytes32[] memory proof
    ) internal view returns (bytes memory) {
        bytes memory submitterData = abi.encode(CCTPSubmitterData(amount, feeRecipient, nonce, deadline, sig));
        return abi.encodeCall(CounterfactualDeposit.execute, (address(cctpImpl), depositParams, submitterData, proof));
    }

    function testPredictDepositAddress() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 merkleRoot = _defaultMerkleRoot();

        address predicted = factory.predictDepositAddress(address(dispatcher), merkleRoot, salt);
        address deployed = factory.deploy(address(dispatcher), merkleRoot, salt);

        assertEq(predicted, deployed, "Predicted address should match deployed");
    }

    function testDeployEmitsEvent() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 merkleRoot = _defaultMerkleRoot();

        vm.expectEmit(true, true, true, true);
        emit ICounterfactualDepositFactory.DepositAddressCreated(
            factory.predictDepositAddress(address(dispatcher), merkleRoot, salt),
            address(dispatcher),
            merkleRoot,
            salt
        );

        factory.deploy(address(dispatcher), merkleRoot, salt);
    }

    function testCannotDeployTwice() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 merkleRoot = _defaultMerkleRoot();

        factory.deploy(address(dispatcher), merkleRoot, salt);

        vm.expectRevert();
        factory.deploy(address(dispatcher), merkleRoot, salt);
    }

    function testDeployedContractStoresCorrectHash() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 merkleRoot = _defaultMerkleRoot();

        address deployed = factory.deploy(address(dispatcher), merkleRoot, salt);

        bytes memory args = Clones.fetchCloneArgs(deployed);
        bytes32 storedHash = abi.decode(args, (bytes32));

        assertEq(storedHash, merkleRoot, "Stored hash should match merkle root");
    }

    function testDeployAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        address depositAddress = factory.predictDepositAddress(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        vm.expectEmit(true, true, true, true);
        emit CounterfactualDepositCCTP.CCTPDepositExecuted(amount, relayer, nonce, block.timestamp + 1 hours);

        bytes memory execCalldata = _executeCalldata(
            depositParams,
            amount,
            relayer,
            nonce,
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        vm.prank(relayer);
        address deployed = factory.deployAndExecute(address(dispatcher), merkleRoot, salt, execCalldata);

        assertEq(deployed, depositAddress, "Deployed address should match prediction");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            burnToken.balanceOf(relayer),
            defaultDepositParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
        assertEq(srcPeriphery.lastNonce(), nonce, "SrcPeriphery should have received correct nonce");
    }

    function testCctpMaxFeeBpsCalculation() public {
        bytes32 salt = keccak256("test-salt");
        bytes32 nonce = keccak256("nonce-1");
        uint256 amount = 100e6;
        uint256 depositAmount = amount - defaultDepositParams.executionFee;

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory submitterData = abi.encode(
            CCTPSubmitterData(amount, relayer, nonce, block.timestamp + 1 hours, bytes("sig"))
        );
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), depositParams, submitterData, proof);

        assertEq(srcPeriphery.lastMaxFee(), (depositAmount * 100) / 10000, "maxFee should be 1% of net deposit amount");
    }

    function testExecuteOnExistingClone() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        // First deposit
        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        bytes memory submitterData1 = abi.encode(
            CCTPSubmitterData(uint256(100e6), relayer, keccak256("nonce-1"), block.timestamp + 1 hours, bytes("sig"))
        );
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), depositParams, submitterData1, proof);

        // Second deposit (reuse same clone)
        vm.prank(user);
        burnToken.transfer(depositAddress, 50e6);

        bytes memory submitterData2 = abi.encode(
            CCTPSubmitterData(uint256(50e6), relayer, keccak256("nonce-2"), block.timestamp + 1 hours, bytes("sig"))
        );
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), depositParams, submitterData2, proof);

        assertEq(srcPeriphery.callCount(), 2, "Should have two deposits");
        assertEq(burnToken.balanceOf(depositAddress), 0, "All tokens should be deposited");
        assertEq(
            burnToken.balanceOf(relayer),
            2 * defaultDepositParams.executionFee,
            "Relayer should receive fees from both deposits"
        );
    }

    function testExecuteViaFactory() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory execCalldata = _executeCalldata(
            depositParams,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        vm.prank(relayer);
        factory.execute(depositAddress, execCalldata);

        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(
            burnToken.balanceOf(relayer),
            defaultDepositParams.executionFee,
            "Relayer should receive execution fee"
        );
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "SrcPeriphery should have received net amount");
    }

    function testAdminWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        (bytes32 merkleRoot, , bytes32[] memory withdrawProof) = _depositAndWithdrawTree(depositParams, withdrawParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        MintableERC20 wrongToken = new MintableERC20("Wrong", "WRONG", 18);
        wrongToken.mint(depositAddress, 100e18);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(wrongToken), admin, 100e18);

        bytes memory submitterData = abi.encode(address(wrongToken), admin, uint256(100e18));
        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            withdrawParams,
            submitterData,
            withdrawProof
        );

        assertEq(wrongToken.balanceOf(admin), 100e18, "Admin should receive withdrawn tokens");
        assertEq(wrongToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testAdminWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        (bytes32 merkleRoot, , bytes32[] memory withdrawProof) = _depositAndWithdrawTree(depositParams, withdrawParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        bytes memory submitterData = abi.encode(address(burnToken), relayer, uint256(100e6));
        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            withdrawParams,
            submitterData,
            withdrawProof
        );
    }

    function testUserWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        (bytes32 merkleRoot, , bytes32[] memory withdrawProof) = _depositAndWithdrawTree(depositParams, withdrawParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        vm.expectEmit(true, true, true, true);
        emit WithdrawImplementation.Withdraw(address(burnToken), user, 100e6);

        bytes memory submitterData = abi.encode(address(burnToken), user, uint256(100e6));
        vm.prank(user);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            withdrawParams,
            submitterData,
            withdrawProof
        );

        assertEq(burnToken.balanceOf(user), 1000e6, "User should have all tokens back");
        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit address should have no balance");
    }

    function testUserWithdrawUnauthorized() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        (bytes32 merkleRoot, , bytes32[] memory withdrawProof) = _depositAndWithdrawTree(depositParams, withdrawParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        bytes memory submitterData = abi.encode(address(burnToken), relayer, uint256(100e6));
        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            withdrawParams,
            submitterData,
            withdrawProof
        );
    }

    function testExecuteOnImplementationReverts() public {
        // Calling execute directly on the dispatcher (not a clone) should revert
        // because fetchCloneArgs will fail on a non-clone address.
        bytes memory depositParams = _encodedDepositParams();
        bytes memory submitterData = abi.encode(
            CCTPSubmitterData(uint256(100e6), relayer, keccak256("nonce"), block.timestamp + 1 hours, bytes("sig"))
        );
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert();
        dispatcher.execute(address(cctpImpl), depositParams, submitterData, proof);
    }

    function testInvalidProof() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, ) = _depositOnlyTree(depositParams);
        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        // Modify deposit params to create mismatched proof
        CCTPDepositParams memory wrongParams = defaultDepositParams;
        wrongParams.cctpMaxFeeBps = 200;
        bytes memory wrongDepositParams = abi.encode(wrongParams);

        // Use the proof from the correct tree but with wrong params
        (, bytes32[] memory proof) = _depositOnlyTree(depositParams);

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        bytes memory submitterData = abi.encode(
            CCTPSubmitterData(uint256(100e6), relayer, keccak256("nonce-1"), block.timestamp + 1 hours, bytes("sig"))
        );
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), wrongDepositParams, submitterData, proof);
    }

    function testInvalidProofOnWithdraw() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        (bytes32 merkleRoot, , bytes32[] memory withdrawProof) = _depositAndWithdrawTree(depositParams, withdrawParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        // Use wrong withdraw params but correct proof
        bytes memory wrongWithdrawParams = abi.encode(WithdrawParams({ admin: relayer, user: user }));

        bytes memory submitterData = abi.encode(address(burnToken), admin, uint256(100e6));
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(admin);
        ICounterfactualDeposit(depositAddress).execute(
            address(withdrawImpl),
            wrongWithdrawParams,
            submitterData,
            withdrawProof
        );
    }

    function testExecuteWithZeroExecutionFee() public {
        CCTPDepositParams memory params = defaultDepositParams;
        params.executionFee = 0;
        bytes memory depositParams = abi.encode(params);

        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        bytes32 salt = keccak256("test-salt-zero-fee");
        uint256 amount = 100e6;

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory submitterData = abi.encode(
            CCTPSubmitterData(amount, relayer, keccak256("nonce-1"), block.timestamp + 1 hours, bytes("sig"))
        );
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), depositParams, submitterData, proof);

        assertEq(burnToken.balanceOf(relayer), 0, "Relayer should receive no fee");
        assertEq(srcPeriphery.lastAmount(), amount, "Full amount should be deposited");
    }

    function testDeployAndExecuteRevertBubble() public {
        bytes32 salt = keccak256("test-salt");

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);

        // Don't fund the clone, so execute will revert on the token transfer
        bytes memory execCalldata = _executeCalldata(
            depositParams,
            100e6,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        vm.expectRevert();
        vm.prank(relayer);
        factory.deployAndExecute(address(dispatcher), merkleRoot, salt, execCalldata);
    }

    function testDeployWithActionData() public {
        bytes32 salt = keccak256("test-salt-action");
        bytes memory actionData = abi.encode(uint256(42), address(0xBEEF));

        CCTPDepositParams memory params = defaultDepositParams;
        params.actionData = actionData;
        bytes memory depositParams = abi.encode(params);

        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);

        address depositAddress = factory.deploy(address(dispatcher), merkleRoot, salt);

        bytes memory args = Clones.fetchCloneArgs(depositAddress);
        bytes32 storedHash = abi.decode(args, (bytes32));
        assertEq(storedHash, merkleRoot, "Stored hash should match merkle root with actionData");

        vm.prank(user);
        burnToken.transfer(depositAddress, 100e6);

        bytes memory submitterData = abi.encode(
            CCTPSubmitterData(uint256(100e6), relayer, keccak256("nonce-1"), block.timestamp + 1 hours, bytes("sig"))
        );
        vm.prank(relayer);
        ICounterfactualDeposit(depositAddress).execute(address(cctpImpl), depositParams, submitterData, proof);

        assertEq(burnToken.balanceOf(depositAddress), 0, "Deposit contract should have no balance left");
        assertEq(srcPeriphery.callCount(), 1, "Deposit should be executed");
    }

    function testDeployIfNeededAndExecute() public {
        bytes32 salt = keccak256("test-salt");
        uint256 amount = 100e6;
        uint256 expectedDeposit = amount - defaultDepositParams.executionFee;

        bytes memory depositParams = _encodedDepositParams();
        (bytes32 merkleRoot, bytes32[] memory proof) = _depositOnlyTree(depositParams);
        address depositAddress = factory.predictDepositAddress(address(dispatcher), merkleRoot, salt);

        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory execCalldata = _executeCalldata(
            depositParams,
            amount,
            relayer,
            keccak256("nonce-1"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        // First call deploys and executes
        vm.prank(relayer);
        address deployed = factory.deployIfNeededAndExecute(address(dispatcher), merkleRoot, salt, execCalldata);
        assertEq(deployed, depositAddress, "Should return predicted address");
        assertEq(srcPeriphery.lastAmount(), expectedDeposit, "First deposit should execute");

        // Second call with clone already deployed -- should not revert
        vm.prank(user);
        burnToken.transfer(depositAddress, amount);

        bytes memory execCalldata2 = _executeCalldata(
            depositParams,
            amount,
            relayer,
            keccak256("nonce-2"),
            block.timestamp + 1 hours,
            "sig",
            proof
        );

        vm.prank(relayer);
        address deployed2 = factory.deployIfNeededAndExecute(address(dispatcher), merkleRoot, salt, execCalldata2);
        assertEq(deployed2, depositAddress, "Should return same address");
        assertEq(srcPeriphery.callCount(), 2, "Both deposits should execute");
    }
}
