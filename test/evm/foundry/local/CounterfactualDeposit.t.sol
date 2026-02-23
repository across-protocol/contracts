// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation, WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualImplementation } from "../../../../contracts/interfaces/ICounterfactualImplementation.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/**
 * @notice Mock implementation that records delegatecall execution and returns data.
 */
contract MockImplementation is ICounterfactualImplementation {
    event MockExecuted(bytes params, bytes submitterData);

    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        emit MockExecuted(params, submitterData);
    }
}

/**
 * @notice Mock implementation that reverts with a custom error.
 */
contract RevertingImplementation is ICounterfactualImplementation {
    error CustomRevert(string reason);

    function execute(bytes calldata, bytes calldata) external payable {
        revert CustomRevert("test revert");
    }
}

contract CounterfactualDepositTest is Test {
    Merkle public merkle;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositFactory public factory;
    MockImplementation public mockImpl;
    RevertingImplementation public revertImpl;
    WithdrawImplementation public withdrawImpl;
    MintableERC20 public token;

    address public user;
    address public admin;
    address public relayer;

    function setUp() public {
        merkle = new Merkle();
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        mockImpl = new MockImplementation();
        revertImpl = new RevertingImplementation();
        withdrawImpl = new WithdrawImplementation();
        token = new MintableERC20("USDC", "USDC", 6);

        user = makeAddr("user");
        admin = makeAddr("admin");
        relayer = makeAddr("relayer");
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(implementation, keccak256(params)));
    }

    function _deployClone(bytes32 merkleRoot, bytes32 salt) internal returns (address) {
        return factory.deploy(address(dispatcher), merkleRoot, salt);
    }

    // --- Single-leaf tree tests ---

    function testExecuteSingleLeaf() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(mockImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        address clone = _deployClone(root, keccak256("salt"));

        vm.expectEmit(false, false, false, true);
        emit MockImplementation.MockExecuted(params, "submitter");

        ICounterfactualDeposit(clone).execute(address(mockImpl), params, "submitter", proof);
    }

    function testInvalidProofReverts() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(mockImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);

        address clone = _deployClone(root, keccak256("salt"));

        // Use wrong params
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(
            address(mockImpl),
            abi.encode(uint256(999)), // wrong params
            "submitter",
            proof
        );
    }

    function testWrongImplementationReverts() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(mockImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        address clone = _deployClone(root, keccak256("salt"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(
            address(revertImpl), // wrong implementation
            params,
            "submitter",
            proof
        );
    }

    function testDelegatecallRevertBubbles() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(revertImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        address clone = _deployClone(root, keccak256("salt"));

        vm.expectRevert(abi.encodeWithSelector(RevertingImplementation.CustomRevert.selector, "test revert"));
        ICounterfactualDeposit(clone).execute(address(revertImpl), params, "", proof);
    }

    // --- Multi-leaf tree tests ---

    function testMultiLeafTree() public {
        bytes memory params1 = abi.encode(uint256(1));
        bytes memory params2 = abi.encode(uint256(2));
        bytes memory params3 = abi.encode(uint256(3));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(mockImpl), params1);
        leaves[1] = _computeLeaf(address(mockImpl), params2);
        leaves[2] = _computeLeaf(address(revertImpl), params3);
        leaves[3] = keccak256("padding");

        bytes32 root = merkle.getRoot(leaves);
        address clone = _deployClone(root, keccak256("multi"));

        // Execute leaf 0
        bytes32[] memory proof0 = merkle.getProof(leaves, 0);
        ICounterfactualDeposit(clone).execute(address(mockImpl), params1, "", proof0);

        // Execute leaf 1
        bytes32[] memory proof1 = merkle.getProof(leaves, 1);
        ICounterfactualDeposit(clone).execute(address(mockImpl), params2, "", proof1);

        // Leaf 2 with revertImpl should revert on execution (proof is valid, impl reverts)
        bytes32[] memory proof2 = merkle.getProof(leaves, 2);
        vm.expectRevert();
        ICounterfactualDeposit(clone).execute(address(revertImpl), params3, "", proof2);
    }

    // --- Typical merkle tree: deposit + withdrawal ---

    function testTypicalMerkleTree() public {
        // Simulate a typical tree with deposit (mock) + single withdraw leaf
        bytes memory depositParams = abi.encode(uint256(42));
        bytes memory withdrawParams = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(mockImpl), depositParams);
        leaves[1] = _computeLeaf(address(withdrawImpl), withdrawParams);

        bytes32 root = merkle.getRoot(leaves);
        address clone = _deployClone(root, keccak256("typical"));

        // Fund clone with ERC20
        token.mint(clone, 100e6);

        // User withdraw
        bytes32[] memory userProof = merkle.getProof(leaves, 1);
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            withdrawParams,
            abi.encode(address(token), user, 50e6),
            userProof
        );
        assertEq(token.balanceOf(user), 50e6);

        // Admin withdraw (same leaf, same proof)
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            withdrawParams,
            abi.encode(address(token), admin, 50e6),
            userProof
        );
        assertEq(token.balanceOf(admin), 50e6);
        assertEq(token.balanceOf(clone), 0);
    }

    // --- Factory integration ---

    function testDeployIfNeededAndExecute() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(mockImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        bytes32 salt = keccak256("factory-test");
        address predicted = factory.predictDepositAddress(address(dispatcher), root, salt);

        bytes memory executeCalldata = abi.encodeCall(
            CounterfactualDeposit.execute,
            (address(mockImpl), params, "submitter", proof)
        );

        address deployed = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata);
        assertEq(deployed, predicted);

        // Second call should not revert (clone already exists)
        deployed = factory.deployIfNeededAndExecute(address(dispatcher), root, salt, executeCalldata);
        assertEq(deployed, predicted);
    }

    // --- Receive ETH ---

    function testCloneAcceptsETH() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256("a");
        leaves[1] = keccak256("b");
        bytes32 root = merkle.getRoot(leaves);

        address clone = _deployClone(root, keccak256("eth"));

        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool success, ) = clone.call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(clone.balance, 1 ether);
    }

    // --- MsgValue forwarding ---

    function testMsgValueForwarded() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32 leaf = _computeLeaf(address(mockImpl), params);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("dummy");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        address clone = _deployClone(root, keccak256("value"));

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute{ value: 0.1 ether }(address(mockImpl), params, "submitter", proof);
    }
}
