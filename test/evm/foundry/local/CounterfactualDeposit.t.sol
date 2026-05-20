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

/// @notice Records the (cloneArgs, params, submitterData) it was called with for assertions.
contract RecordingImplementation is ICounterfactualImplementation {
    event Recorded(CloneArgs cloneArgs, bytes params, bytes submitterData);

    function execute(
        CloneArgs calldata cloneArgs,
        bytes calldata params,
        bytes calldata submitterData
    ) external payable {
        emit Recorded(cloneArgs, params, submitterData);
    }
}

contract RevertingImplementation is ICounterfactualImplementation {
    error CustomRevert(string reason);

    function execute(CloneArgs calldata, bytes calldata, bytes calldata) external payable {
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

    /// @dev Leaf params for a recording impl. Mirrors the wire format of `abi.encode(StructWithDynamicField)`:
    ///      a 0x20 offset pointer, then `(destinationChainId, outputToken, ...tail)`. The dispatcher's
    ///      identity check reads the two fields past the offset pointer.
    function _routeParams(
        uint256 destChainId,
        bytes32 outputToken,
        bytes memory tail
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(uint256(0x20), destChainId, outputToken, tail);
    }

    function _computeLeaf(address impl, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(impl, keccak256(params)))));
    }

    function _setPolicyRoot(bytes32 root) internal {
        vm.prank(policyOwner);
        policy.updateRoot(root);
    }

    function _buildTreeWithSingleLeaf(
        address impl,
        bytes memory params
    ) internal returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(impl, params);
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
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);
        token.mint(clone, 100e6);

        // A non-withdrawUser calling with the withdraw impl falls through to the proof path,
        // where the leaf check requires `params.length >= 64`.
        vm.expectRevert(ICounterfactualDeposit.ParamsTooShort.selector);
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

        vm.expectRevert(ICounterfactualDeposit.ParamsTooShort.selector);
        vm.prank(withdrawUser);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(recImpl), "", "", new bytes32[](0));
    }

    // --- Identity check ---

    function testMismatchedDestinationChainIdReverts() public {
        bytes32 outputToken = _cloneArgs().outputToken;
        bytes memory params = _routeParams(999, outputToken, abi.encode(uint256(42)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        vm.expectRevert(ICounterfactualDeposit.InvalidIdentity.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(recImpl), params, "", proof);
    }

    function testMismatchedOutputTokenReverts() public {
        bytes32 wrongToken = bytes32(uint256(uint160(makeAddr("wrong-token"))));
        bytes memory params = _routeParams(_cloneArgs().destinationChainId, wrongToken, abi.encode(uint256(42)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        vm.expectRevert(ICounterfactualDeposit.InvalidIdentity.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(recImpl), params, "", proof);
    }

    function testParamsTooShortReverts() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), SALT);

        // Need at least 96 bytes (wrapper offset + two identity fields).
        bytes memory shortParams = abi.encode(uint256(0x20), uint256(1));
        vm.expectRevert(ICounterfactualDeposit.ParamsTooShort.selector);
        ICounterfactualDeposit(clone).execute(_cloneArgs(), address(recImpl), shortParams, "", new bytes32[](0));
    }

    // --- Proof verification against RoutePolicy.activeRoot() ---

    function testValidProofExecutesImpl() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(42)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(args, params, "submitter");

        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "submitter", proof);
    }

    function testInvalidProofReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(42)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        // Same first two fields (identity passes) but different tail → different leaf → proof fails.
        bytes memory wrongParams = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(999)));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), wrongParams, "", proof);
    }

    function testProofAgainstStaleRootReverts() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(42)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        // Update the policy root → old proof is stale.
        _setPolicyRoot(keccak256("new-root"));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "", proof);
    }

    function testNewRootAuthorizesPreviouslyInvalidLeaf() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory paramsA = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(1)));
        bytes memory paramsB = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(2)));

        (bytes32 rootA, bytes32[] memory proofA) = _buildTreeWithSingleLeaf(address(recImpl), paramsA);
        (bytes32 rootB, bytes32[] memory proofB) = _buildTreeWithSingleLeaf(address(recImpl), paramsB);

        _setPolicyRoot(rootA);
        address clone = factory.deploy(address(dispatcher), args, SALT);

        // Leaf A works under root A.
        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsA, "", proofA);

        // Leaf B doesn't work under root A.
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsB, "", proofB);

        // After updating to root B, leaf B works.
        _setPolicyRoot(rootB);
        ICounterfactualDeposit(clone).execute(args, address(recImpl), paramsB, "", proofB);
    }

    // --- Delegatecall semantics ---

    function testImplReceivesVerifiedCloneArgs() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(7)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(recImpl), params);
        _setPolicyRoot(root);

        address clone = factory.deploy(address(dispatcher), args, SALT);

        // The impl should observe the exact cloneArgs the dispatcher verified.
        vm.expectEmit(false, false, false, true);
        emit RecordingImplementation.Recorded(args, params, "data");

        ICounterfactualDeposit(clone).execute(args, address(recImpl), params, "data", proof);
    }

    function testRevertingImplBubblesError() public {
        CloneArgs memory args = _cloneArgs();
        bytes memory params = _routeParams(args.destinationChainId, args.outputToken, abi.encode(uint256(7)));
        (bytes32 root, bytes32[] memory proof) = _buildTreeWithSingleLeaf(address(revImpl), params);
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
