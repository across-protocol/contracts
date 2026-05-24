// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { WithdrawImplementation } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { deployRoutePolicy } from "../utils/RoutePolicyTestHelper.sol";
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
        address admin,
        bytes routeParams,
        bytes submitterData
    );

    function execute(
        bytes32 recipient,
        bytes32 outputToken,
        uint256 destinationChainId,
        address admin,
        bytes calldata routeParams,
        bytes calldata submitterData
    ) external payable {
        emit Recorded(recipient, outputToken, destinationChainId, admin, routeParams, submitterData);
    }
}

contract RevertingImplementation is ICounterfactualImplementation {
    error CustomRevert(string reason);

    function execute(bytes32, bytes32, uint256, address, bytes calldata, bytes calldata) external payable {
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

    address public admin;
    address public relayer;
    address public policyOwner;

    bytes32 public constant SALT = keccak256("salt");

    function setUp() public {
        merkle = new Merkle();
        withdrawImpl = new WithdrawImplementation();
        dispatcher = new CounterfactualDeposit();
        factory = new CounterfactualDepositFactory();
        recImpl = new RecordingImplementation();
        revImpl = new RevertingImplementation();
        token = new MintableERC20("USDC", "USDC", 6);

        admin = makeAddr("admin");
        relayer = makeAddr("relayer");
        policyOwner = makeAddr("policyOwner");
        policy = deployRoutePolicy(policyOwner, bytes32(0));
    }

    function _cloneArgs() internal returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(token)))),
                destinationChainId: 42161,
                recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
                admin: admin,
                routePolicyAddress: address(policy)
            });
    }

    function _computeLeaf(
        address impl,
        bytes32 outputToken,
        uint256 destChainId,
        bytes memory routeParams
    ) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, outputToken, destChainId, keccak256(routeParams)))));
    }

    function _setPolicyRoot(bytes32 root) internal {
        vm.prank(policyOwner);
        policy.updateRoot(root);
    }

    /// @dev Build a tree with a single leaf of interest. Murky needs ≥2 leaves so we add a padding leaf.
    function _buildTreeWithSingleLeaf(
        CloneArgs memory args,
        address impl,
        bytes memory routeParams
    ) internal returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(impl, args.outputToken, args.destinationChainId, routeParams);
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
            abi.encode(address(token), admin, uint256(0)),
            new bytes32[](0)
        );
    }

    function testTamperedAdminReverts() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        CloneArgs memory tampered = _cloneArgs();
        tampered.admin = address(this);

        vm.expectRevert(ICounterfactualDeposit.InvalidCloneArgs.selector);
        ICounterfactualDeposit(clone).execute(
            tampered,
            address(withdrawImpl),
            "",
            abi.encode(address(token), address(this), uint256(100e6)),
            new bytes32[](0)
        );
    }

    // --- Admin escape ---

    function testAdminEscapeBypassesProofForWithdrawImpl() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        // Policy root is bytes32(0) — no proof can verify. The admin escape should still work.
        assertEq(policy.activeRoot(address(0)), bytes32(0));

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(token), admin, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(token.balanceOf(admin), 100e6);
    }

    function testAdminEscapeBypassesProofForAnyImpl() public {
        // Admin can call any impl — not just the withdraw impl. Here they call a recording impl
        // that's never been added to the policy tree, with arbitrary routeParams.
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(0xDEAD));

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(
            args.recipient,
            args.outputToken,
            args.destinationChainId,
            args.admin,
            routeParams,
            "data"
        );

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParams, "data", new bytes32[](0));
    }

    function testNonAdminCallerHitsProofPath() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        // Non-admin caller falls through to the proof path, which fails because no proof matches
        // against a bytes32(0) root.
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

    function testWithdrawImplRejectsNonAdminEvenWithValidProof() public {
        // Defense-in-depth: even if a policy tree mistakenly includes a withdrawImpl leaf, the
        // impl itself rejects non-admin callers based on the dispatcher-forwarded `admin` arg.
        CloneArgs memory args = _cloneArgs();
        // Withdraw impl uses empty routeParams.
        bytes memory routeParams = "";
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(withdrawImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);
        token.mint(clone, 100e6);

        // Proof verifies, dispatcher delegatecalls withdrawImpl, withdrawImpl reverts.
        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            args,
            address(withdrawImpl),
            routeParams,
            abi.encode(address(token), relayer, uint256(100e6)),
            proof
        );
    }

    // --- Leaf is bound to clone identity ---

    function testLeafBoundToCloneIdentity() public {
        // Build a tree with a leaf authored for clone A's identity (outputToken, destChainId).
        CloneArgs memory argsA = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(argsA, address(recImpl), routeParams);
        _setPolicyRoot(root);

        // Clone A can prove the leaf.
        address cloneA = factory.deploy(address(dispatcher), argsA, SALT);
        ICounterfactualDeposit(cloneA).execute(argsA, address(recImpl), routeParams, "", proof);

        // Clone B (same policy, different outputToken) cannot — the leaf preimage commits to argsA's outputToken.
        CloneArgs memory argsB = _cloneArgs();
        argsB.outputToken = bytes32(uint256(uint160(makeAddr("other-token"))));
        address cloneB = factory.deploy(address(dispatcher), argsB, keccak256("salt-b"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(cloneB).execute(argsB, address(recImpl), routeParams, "", proof);
    }

    function testLeafBoundToDestinationChainId() public {
        // Same as above but vary destinationChainId.
        CloneArgs memory argsA = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(argsA, address(recImpl), routeParams);
        _setPolicyRoot(root);

        address cloneA = factory.deploy(address(dispatcher), argsA, SALT);
        ICounterfactualDeposit(cloneA).execute(argsA, address(recImpl), routeParams, "", proof);

        CloneArgs memory argsB = _cloneArgs();
        argsB.destinationChainId = 10; // different chain
        address cloneB = factory.deploy(address(dispatcher), argsB, keccak256("salt-c"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(cloneB).execute(argsB, address(recImpl), routeParams, "", proof);
    }

    // --- Proof verification against RoutePolicy.activeRoot() ---

    function testValidProofExecutesImpl() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(
            args.recipient,
            args.outputToken,
            args.destinationChainId,
            args.admin,
            routeParams,
            "submitter"
        );

        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParams, "submitter", proof);
    }

    function testInvalidProofReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        // Different routeParams → different leaf → proof fails.
        bytes memory wrongParams = abi.encode(uint256(999));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), wrongParams, "", proof);
    }

    function testProofAgainstStaleRootReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(42));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        _setPolicyRoot(keccak256("new-root"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParams, "", proof);
    }

    function testNewRootAuthorizesPreviouslyInvalidLeaf() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParamsA = abi.encode(uint256(1));
        bytes memory routeParamsB = abi.encode(uint256(2));

        (bytes32 rootA, bytes32[] memory proofA) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParamsA);
        (bytes32 rootB, bytes32[] memory proofB) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParamsB);

        _setPolicyRoot(rootA);
        address clone = factory.deploy(address(dispatcher), args, SALT);

        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParamsA, "", proofA);

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParamsB, "", proofB);

        _setPolicyRoot(rootB);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParamsB, "", proofB);
    }

    // --- Delegatecall semantics ---

    function testImplReceivesVerifiedCloneArgs() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(7));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(recImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(
            args.recipient,
            args.outputToken,
            args.destinationChainId,
            args.admin,
            routeParams,
            "data"
        );

        ICounterfactualDeposit(clone).execute(args, address(recImpl), routeParams, "data", proof);
    }

    function testRevertingImplBubblesError() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory routeParams = abi.encode(uint256(7));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(args, address(revImpl), routeParams);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectRevert(abi.encodeWithSelector(RevertingImplementation.CustomRevert.selector, "test revert"));
        ICounterfactualDeposit(clone).execute(args, address(revImpl), routeParams, "", proof);
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
