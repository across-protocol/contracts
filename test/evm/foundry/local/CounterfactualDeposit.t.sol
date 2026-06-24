// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    CounterfactualBeacon,
    CounterfactualChainConfig
} from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { CounterfactualBeaconBase } from "../../../../contracts/periphery/counterfactual/CounterfactualBeaconBase.sol";
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { ICounterfactualImplementation } from "../../../../contracts/interfaces/ICounterfactualImplementation.sol";
import {
    WithdrawImplementation,
    WithdrawParams
} from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Records that it ran (under the proxy's delegatecall) and echoes its args.
contract MockImplementation is ICounterfactualImplementation {
    event MockExecuted(bytes params, bytes submitterData, uint256 value);

    function execute(bytes calldata params, bytes calldata submitterData) external payable {
        emit MockExecuted(params, submitterData, msg.value);
    }
}

/// @notice Reverts with a custom error to verify bubbling.
contract RevertingImplementation is ICounterfactualImplementation {
    error CustomRevert(string reason);

    function execute(bytes calldata, bytes calldata) external payable {
        revert CustomRevert("boom");
    }
}

/// @notice V2 implementation: same storage layout, plus a `version()` marker.
contract CounterfactualDepositV2 is CounterfactualDeposit {
    constructor(ICounterfactualBeacon beacon_) CounterfactualDeposit(beacon_) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Lets us call `version()` on a proxy via the impl.
interface IVersioned {
    function version() external view returns (uint256);
}

contract CounterfactualDepositTest is CounterfactualTestBase {
    MockImplementation internal mockImpl;
    RevertingImplementation internal revertImpl;
    MintableERC20 internal token;

    function setUp() public {
        _setUpCore();
        _deployBeacon(_baseConfig());
        mockImpl = new MockImplementation();
        revertImpl = new RevertingImplementation();
        token = new MintableERC20("USDC", "USDC", 6);
    }

    /// @dev Two-leaf tree [leaf0, padding]; deploy the proxy at `initialRoot` and return (proxy, proof0).
    function _deploySingleLeaf(bytes32 leaf0, bytes32 salt) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf0;
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        proxy = factory.deploy(salt, root);
    }

    // --- Beacon ---

    function testBeaconWiring() public view {
        assertEq(beacon.implementation(), address(cfImpl));
        assertEq(beacon.owner(), owner);
        assertEq(address(cfImpl.BEACON()), address(beacon));
        assertEq(address(factory.BEACON()), address(beacon));
    }

    function testSetImplementationOnlyOwner() public {
        vm.expectRevert();
        beacon.setImplementation(address(mockImpl));
    }

    function testSetImplementationRejectsEOA() public {
        vm.prank(owner);
        vm.expectRevert(CounterfactualBeaconBase.NotAContract.selector);
        beacon.setImplementation(makeAddr("eoa"));
    }

    function testSetImplementationRejectsWrongBeacon() public {
        // A valid impl contract, but bound to a different beacon.
        CounterfactualDeposit wrong = new CounterfactualDeposit(ICounterfactualBeacon(makeAddr("otherBeacon")));
        vm.prank(owner);
        vm.expectRevert(CounterfactualBeaconBase.WrongBeacon.selector);
        beacon.setImplementation(address(wrong));
    }

    function testSetImplementationRejectsNonConformingContract() public {
        // No `BEACON()` getter: the try/catch leaves it unbound, so it is rejected.
        vm.prank(owner);
        vm.expectRevert(CounterfactualBeaconBase.WrongBeacon.selector);
        beacon.setImplementation(address(mockImpl));
    }

    function testSetUpgradeRootOnlyOwner() public {
        vm.expectRevert();
        beacon.setUpgradeRoot(keccak256("root"));
    }

    function testInitializeRejectsEoaImplementation() public {
        address logic = address(new CounterfactualBeacon(_baseConfig()));
        vm.expectRevert(CounterfactualBeaconBase.NotAContract.selector);
        new ERC1967Proxy(
            logic,
            abi.encodeCall(CounterfactualBeaconBase.initialize, (owner, makeAddr("eoa"), bytes32(0)))
        );
    }

    function testInitializeAllowsZeroImplementation() public {
        // Lazy init (address(0)) is permitted; base `setUp` relies on this.
        address logic = address(new CounterfactualBeacon(_baseConfig()));
        CounterfactualBeacon b = CounterfactualBeacon(
            address(
                new ERC1967Proxy(
                    logic,
                    abi.encodeCall(CounterfactualBeaconBase.initialize, (owner, address(0), bytes32(0)))
                )
            )
        );
        assertEq(b.implementation(), address(0));
    }

    // --- Deploy + dispatch ---

    function testDeployIsDeterministicAndInitializesRoot() public {
        bytes32 leaf = _leaf(address(mockImpl), abi.encode(uint256(1)));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = leaf;
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);

        address predicted = factory.predictAddress(bytes32(0), root);
        address deployed = factory.deploy(bytes32(0), root);

        assertEq(predicted, deployed);
        assertEq(CounterfactualDeposit(payable(deployed)).activeRoot(), root);
    }

    function testSaltYieldsDistinctAddresses() public {
        bytes32 root = keccak256("root");
        assertTrue(factory.predictAddress(bytes32(0), root) != factory.predictAddress(keccak256("s2"), root));
    }

    function testExecuteDispatches() public {
        bytes memory params = abi.encode(uint256(123));
        (address proxy, bytes32[] memory proof) = _deploySingleLeaf(_leaf(address(mockImpl), params), bytes32(0));

        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(params, "submitter", 0);
        ICounterfactualDeposit(proxy).execute(address(mockImpl), params, "submitter", proof);
    }

    function testExecuteForwardsValue() public {
        bytes memory params = abi.encode(uint256(1));
        (address proxy, bytes32[] memory proof) = _deploySingleLeaf(_leaf(address(mockImpl), params), bytes32(0));

        vm.deal(relayer, 1 ether);
        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(params, "", 0.5 ether);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute{ value: 0.5 ether }(address(mockImpl), params, "", proof);
    }

    function testExecuteInvalidProofReverts() public {
        bytes memory params = abi.encode(uint256(123));
        (address proxy, bytes32[] memory proof) = _deploySingleLeaf(_leaf(address(mockImpl), params), bytes32(0));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(proxy).execute(address(mockImpl), abi.encode(uint256(999)), "", proof);
    }

    function testExecuteWrongImplementationReverts() public {
        bytes memory params = abi.encode(uint256(123));
        (address proxy, bytes32[] memory proof) = _deploySingleLeaf(_leaf(address(mockImpl), params), bytes32(0));

        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(proxy).execute(address(revertImpl), params, "", proof);
    }

    function testExecuteBubblesRevert() public {
        bytes memory params = abi.encode(uint256(7));
        (address proxy, bytes32[] memory proof) = _deploySingleLeaf(_leaf(address(revertImpl), params), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(RevertingImplementation.CustomRevert.selector, "boom"));
        ICounterfactualDeposit(proxy).execute(address(revertImpl), params, "", proof);
    }

    function testMultiLeafTree() public {
        bytes memory p1 = abi.encode(uint256(1));
        bytes memory p2 = abi.encode(uint256(2));
        bytes memory p3 = abi.encode(uint256(3));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(mockImpl), p1);
        leaves[1] = _leaf(address(mockImpl), p2);
        leaves[2] = _leaf(address(revertImpl), p3);
        leaves[3] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        // Precompute proofs before the cheatcodes: the external `merkle.getProof` calls would otherwise
        // consume the `vm.expectEmit`/`vm.expectRevert` meant for `execute`.
        bytes32[] memory proof0 = merkle.getProof(leaves, 0);
        bytes32[] memory proof1 = merkle.getProof(leaves, 1);
        bytes32[] memory proof2 = merkle.getProof(leaves, 2);
        address proxy = factory.deploy(bytes32(0), root);

        // Two mock leaves on the same proxy both dispatch.
        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(p1, "", 0);
        ICounterfactualDeposit(proxy).execute(address(mockImpl), p1, "", proof0);

        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(p2, "", 0);
        ICounterfactualDeposit(proxy).execute(address(mockImpl), p2, "", proof1);

        // The reverting leaf is provable but bubbles its revert.
        vm.expectRevert(abi.encodeWithSelector(RevertingImplementation.CustomRevert.selector, "boom"));
        ICounterfactualDeposit(proxy).execute(address(revertImpl), p3, "", proof2);
    }

    function testDeployIfNeededAndExecuteIsIdempotent() public {
        bytes memory params = abi.encode(uint256(123));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(mockImpl), params);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);

        address predicted = factory.predictAddress(bytes32(0), root);
        bytes memory exec = abi.encodeCall(
            CounterfactualDeposit.execute,
            (address(mockImpl), params, "submitter", proof)
        );

        // First call deploys the proxy, then executes.
        vm.expectEmit(predicted);
        emit MockImplementation.MockExecuted(params, "submitter", 0);
        address deployed = factory.deployIfNeededAndExecute(bytes32(0), root, exec);
        assertEq(deployed, predicted);
        assertGt(predicted.code.length, 0);

        // Second call finds the proxy deployed and just executes.
        vm.expectEmit(predicted);
        emit MockImplementation.MockExecuted(params, "submitter", 0);
        address again = factory.deployIfNeededAndExecute(bytes32(0), root, exec);
        assertEq(again, predicted);
    }

    function testProxyAcceptsEth() public {
        (address proxy, ) = _deploySingleLeaf(keccak256("x"), bytes32(0));
        vm.deal(user, 1 ether);
        vm.prank(user);
        (bool ok, ) = proxy.call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(proxy.balance, 1 ether);
    }

    // --- Withdraw leaf (gated to admin/user) ---

    function testWithdrawGating() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        bytes memory deposit = abi.encode(uint256(1));

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(mockImpl), deposit);
        leaves[1] = _leaf(address(withdrawImpl), wp);
        bytes32 root = merkle.getRoot(leaves);
        address proxy = factory.deploy(bytes32(0), root);
        bytes32[] memory wproof = merkle.getProof(leaves, 1);

        token.mint(proxy, 100e6);

        // Stranger cannot withdraw.
        vm.expectRevert(WithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), relayer, 100e6),
            wproof
        );

        // User can.
        vm.prank(user);
        ICounterfactualDeposit(proxy).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), user, 40e6),
            wproof
        );
        assertEq(token.balanceOf(user), 40e6);

        // Admin can.
        vm.prank(admin);
        ICounterfactualDeposit(proxy).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(token), admin, 60e6),
            wproof
        );
        assertEq(token.balanceOf(admin), 60e6);
        assertEq(token.balanceOf(proxy), 0);
    }

    // --- updateRoot ---

    function testUpdateRoot() public {
        (address proxy, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(1))), bytes32(0));
        bytes32 newRoot = keccak256("new-route-set");
        bytes32[] memory proof = _setUpgradeTree(proxy, newRoot);

        vm.expectEmit(address(proxy));
        emit CounterfactualDeposit.RootUpdated(newRoot);
        CounterfactualDeposit(payable(proxy)).updateRoot(newRoot, proof);
        assertEq(CounterfactualDeposit(payable(proxy)).activeRoot(), newRoot);
    }

    function testUpdateRootForgedProofReverts() public {
        (address proxy, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(1))), bytes32(0));
        bytes32 newRoot = keccak256("new-route-set");
        _setUpgradeTree(proxy, newRoot);

        // Prove a root other than the one committed for this proxy.
        bytes32[] memory bad = new bytes32[](1);
        bad[0] = keccak256("garbage");
        vm.expectRevert(CounterfactualDeposit.InvalidUpgradeProof.selector);
        CounterfactualDeposit(payable(proxy)).updateRoot(keccak256("attacker-root"), bad);
    }

    function testUpdateRootWrongProxyReverts() public {
        (address proxyA, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(1))), bytes32(0));
        (address proxyB, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(2))), keccak256("b"));
        bytes32 newRoot = keccak256("new-route-set");
        // Upgrade tree authorizes proxyA only; proxyB tries to use A's proof.
        bytes32[] memory proofA = _setUpgradeTree(proxyA, newRoot);

        vm.expectRevert(CounterfactualDeposit.InvalidUpgradeProof.selector);
        CounterfactualDeposit(payable(proxyB)).updateRoot(newRoot, proofA);
    }

    function testUpdateRootNoOpReverts() public {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(mockImpl), abi.encode(uint256(1)));
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        address proxy = factory.deploy(bytes32(0), root);

        bytes32[] memory proof = _setUpgradeTree(proxy, root); // same as activeRoot
        vm.expectRevert(CounterfactualDeposit.RootUnchanged.selector);
        CounterfactualDeposit(payable(proxy)).updateRoot(root, proof);
    }

    // --- updateRootAndExecute ---

    function testUpdateRootAndExecuteActivatesNewRoute() public {
        // Initial root does NOT contain the mock leaf.
        bytes32[] memory initLeaves = new bytes32[](2);
        initLeaves[0] = keccak256("old-route");
        initLeaves[1] = keccak256("padding");
        bytes32 initialRoot = merkle.getRoot(initLeaves);
        address proxy = factory.deploy(bytes32(0), initialRoot);

        // New route contains the mock leaf.
        bytes memory params = abi.encode(uint256(123));
        bytes32[] memory newLeaves = new bytes32[](2);
        newLeaves[0] = _leaf(address(mockImpl), params);
        newLeaves[1] = keccak256("padding2");
        bytes32 newRoot = merkle.getRoot(newLeaves);
        bytes32[] memory execProof = merkle.getProof(newLeaves, 0);

        // New route fails before activation.
        vm.expectRevert(ICounterfactualDeposit.InvalidProof.selector);
        ICounterfactualDeposit(proxy).execute(address(mockImpl), params, "", execProof);

        bytes32[] memory updateProof = _setUpgradeTree(proxy, newRoot);

        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(params, "submitter", 0);
        ICounterfactualDeposit(proxy).updateRootAndExecute(
            newRoot,
            updateProof,
            address(mockImpl),
            params,
            "submitter",
            execProof
        );
        assertEq(CounterfactualDeposit(payable(proxy)).activeRoot(), newRoot);
    }

    function testUpdateRootAndExecuteSkipsUpdateWhenCurrent() public {
        // Proxy already at the route root; the update step must be skipped (no RootUnchanged revert).
        bytes memory params = abi.encode(uint256(5));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(mockImpl), params);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        address proxy = factory.deploy(bytes32(0), root);
        bytes32[] memory execProof = merkle.getProof(leaves, 0);

        // Bogus update proof is fine: newRoot == activeRoot ⇒ update skipped.
        bytes32[] memory bogus = new bytes32[](1);
        bogus[0] = keccak256("ignored");

        vm.expectEmit(address(proxy));
        emit MockImplementation.MockExecuted(params, "", 0);
        ICounterfactualDeposit(proxy).updateRootAndExecute(root, bogus, address(mockImpl), params, "", execProof);
    }

    // --- Global retargeting via the beacon ---

    function testSetImplementationRetargetsAllProxies() public {
        (address proxyA, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(1))), bytes32(0));
        (address proxyB, ) = _deploySingleLeaf(_leaf(address(mockImpl), abi.encode(uint256(2))), keccak256("b"));

        // Before retargeting the impl has no `version()`.
        vm.expectRevert();
        IVersioned(proxyA).version();

        CounterfactualDepositV2 v2 = new CounterfactualDepositV2(ICounterfactualBeacon(address(beacon)));
        vm.prank(owner);
        beacon.setImplementation(address(v2));

        // Both existing proxies resolve the new implementation.
        assertEq(IVersioned(proxyA).version(), 2);
        assertEq(IVersioned(proxyB).version(), 2);

        // Storage (activeRoot) survives the retarget.
        assertTrue(CounterfactualDeposit(payable(proxyA)).activeRoot() != bytes32(0));
    }
}
