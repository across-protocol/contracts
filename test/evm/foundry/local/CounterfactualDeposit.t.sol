// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualImplementation } from "../../../../contracts/interfaces/ICounterfactualImplementation.sol";
import {
    CloneArgs,
    CounterfactualCloneArgs
} from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Records the args it was called with for assertions.
contract RecordingImplementation is ICounterfactualImplementation {
    event Recorded(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes routeParams,
        bytes submitterData
    );

    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable {
        emit Recorded(recipient, outputToken, destinationChainId, routeParams, submitterData);
    }
}

contract RevertingImplementation is ICounterfactualImplementation {
    error CustomRevert(string reason);

    function execute(bytes32, bytes32, uint256, bytes calldata, bytes calldata) external payable {
        revert CustomRevert("test revert");
    }
}

contract CounterfactualDepositTest is Test {
    using CounterfactualCloneArgs for CloneArgs;

    Merkle public merkle;
    CounterfactualDeposit public dispatcher;
    CounterfactualDepositFactory public factory;
    WithdrawImplementation public withdrawImpl;
    RecordingImplementation public recImpl;
    RevertingImplementation public revImpl;
    RoutePolicy public policy;
    MintableERC20 public token;

    address public withdrawUser;
    address public relayer;
    address public policyOwner;

    bytes32 public constant SALT = keccak256("salt");

    function setUp() public {
        merkle = new Merkle();
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit(address(withdrawImpl));
        factory = new CounterfactualDepositFactory();
        recImpl = new RecordingImplementation();
        revImpl = new RevertingImplementation();
        token = new MintableERC20("USDC", "USDC", 6);

        withdrawUser = makeAddr("withdrawUser");
        relayer = makeAddr("relayer");
        policyOwner = makeAddr("policyOwner");
        policy = new RoutePolicy(policyOwner, bytes32(0));
    }

    function _cloneArgs() internal returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(token)))),
                destinationChainId: 42161,
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                withdrawUser: withdrawUser,
                routePolicyAddress: address(policy)
            });
    }

    function _computeLeaf(
        address impl,
        bytes32 outputToken,
        uint256 destChainId,
        bytes memory params
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, outputToken, destChainId, keccak256(params)))));
    }

    function _setPolicyRoot(bytes32 root) internal {
        vm.prank(policyOwner);
        policy.updateRoot(root);
    }

    /// @dev Build a tree with a single leaf of interest. Murky needs ≥2 leaves so we add a padding leaf.
    function _buildTreeWithSingleLeaf(
        CloneArgs memory args,
        address impl,
        bytes memory params
    ) internal returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(impl, args.outputToken, args.destinationChainId, params);
        leaves[1] = keccak256("padding");
        root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
    }

    // --- cloneArgs hash verification ---

    function testTamperedCloneArgsReverts() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        CloneArgs memory tampered = _cloneArgs();
        tampered.recipient = bytes32(uint256(uint160(makeAddr("attacker"))));

        vm.expectRevert(ICounterfactualDeposit.InvalidCloneArgs.selector);
        ICounterfactualDeposit(clone).execute(
            tampered,
            address(withdrawImpl),
            "",
            abi.encode(address(token), withdrawUser, uint256(0)),
            new bytes32[](0)
        );
    }

    function testTamperedWithdrawUserReverts() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        CloneArgs memory tampered = _cloneArgs();
        tampered.withdrawUser = address(this);

        vm.expectRevert(ICounterfactualDeposit.InvalidCloneArgs.selector);
        ICounterfactualDeposit(clone).execute(
            tampered,
            address(withdrawImpl),
            "",
            abi.encode(address(token), address(this), uint256(100e6)),
            new bytes32[](0)
        );
    }

    // --- Structural withdraw escape ---

    function testWithdrawEscapeBypassesProof() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        // Policy root is bytes32(0) — no proof can verify. The escape should still work.
        assertEq(policy.activeRoot(), bytes32(0));

        vm.prank(withdrawUser);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), withdrawUser, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(token.balanceOf(withdrawUser), 100e6);
    }

    function testWithdrawEscapeWrongCallerFallsThroughToProofPath() public {
        // A non-withdrawUser calling with the withdraw impl falls through to the proof path,
        // which fails because no proof matches against a bytes32(0) root.
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), relayer, uint256(50e6)),
            new bytes32[](0)
        );
    }

    function testWithdrawEscapeWrongImplFallsThroughToProofPath() public {
        // Calling with a different impl AS withdrawUser still falls through to the proof path.
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        vm.prank(withdrawUser);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(recImpl), "", "", new bytes32[](0));
    }

    // --- Leaf is bound to clone identity ---

    function testLeafBoundToCloneIdentity() public {
        // Build a tree with a leaf authored for clone A's identity (outputToken, destChainId).
        CloneArgs memory argsA = _cloneArgs();
        bytes memory params = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(argsA, address(recImpl), params);
        _setPolicyRoot(root);

        // Clone A can prove the leaf.
        address cloneA = factory.deploy(address(dispatcher), argsA, SALT);
        ICounterfactualDeposit(cloneA).execute(argsA, address(recImpl), params, "", proof);

        // Clone B (same policy, different outputToken) cannot — the leaf preimage commits to argsA's outputToken.
        CloneArgs memory argsB = _cloneArgs();
        argsB.outputToken = bytes32(uint256(uint160(makeAddr("other-token"))));
        address cloneB = factory.deploy(address(dispatcher), argsB, keccak256("salt-b"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(cloneB).execute(argsB, address(recImpl), params, "", proof);
    }

    function testLeafBoundToDestinationChainId() public {
        // Same as above but vary destinationChainId.
        CloneArgs memory argsA = _cloneArgs();
        bytes memory params = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(argsA, address(recImpl), params);
        _setPolicyRoot(root);

        address cloneA = factory.deploy(address(dispatcher), argsA, SALT);
        ICounterfactualDeposit(cloneA).execute(argsA, address(recImpl), params, "", proof);

        CloneArgs memory argsB = _cloneArgs();
        argsB.destinationChainId = 10; // different chain
        address cloneB = factory.deploy(address(dispatcher), argsB, keccak256("salt-c"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(cloneB).execute(argsB, address(recImpl), params, "", proof);
    }

    // --- Proof verification against RoutePolicy.activeRoot() ---

    function testValidProofExecutesImpl() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(
            args.recipient,
            args.outputToken,
            args.destinationChainId,
            params,
            "submitter"
        );

        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "submitter", proof);
    }

    function testInvalidProofReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        // Different params → different leaf → proof fails.
        bytes memory wrongParams = abi.encode(uint256(999));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), wrongParams, "", proof);
    }

    function testProofAgainstStaleRootReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        _setPolicyRoot(keccak256("new-root"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "", proof);
    }

    function testNewRootAuthorizesPreviouslyInvalidLeaf() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory paramsA = abi.encode(uint256(1));
        bytes memory paramsB = abi.encode(uint256(2));

        (bytes32 rootA, bytes32[] memory proofA) = _buildTreeWithSingleLeaf(args, address(recImpl), paramsA);
        (bytes32 rootB, bytes32[] memory proofB) = _buildTreeWithSingleLeaf(args, address(recImpl), paramsB);

        _setPolicyRoot(rootA);
        address clone = factory.deploy(address(dispatcher), args, SALT);

        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsA, "", proofA);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsB, "", proofB);

        _setPolicyRoot(rootB);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsB, "", proofB);
    }

    // --- Delegatecall semantics ---

    function testImplReceivesVerifiedCloneArgs() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = abi.encode(uint256(7));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(
            args.recipient,
            args.outputToken,
            args.destinationChainId,
            params,
            "data"
        );

        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "data", proof);
    }

    function testRevertingImplBubblesError() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = abi.encode(uint256(7));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(revImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectRevert(abi.encodeWithSelector(RevertingImplementation.CustomRevert.selector, "test revert"));
        ICounterfactualDeposit(clone).execute(args, address(revImpl), params, "", proof);
    }

    // --- Clone identity ---

    function testCloneStoresArgsHash() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        bytes memory stored = Clones.fetchCloneArgs(clone);
        bytes32 storedHash = abi.decode(stored, (bytes32));

        assertEq(storedHash, _cloneArgs().hash());
    }

    function testCloneAcceptsETH() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        vm.deal(relayer, 1 ether);
        vm.prank(relayer);
        (bool success, ) = clone.call{ value: 1 ether }("");
        assertTrue(success);
        assertEq(clone.balance, 1 ether);
    }
}
