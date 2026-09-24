// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { stdError } from "forge-std/Test.sol";
import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { HyperCoreMockHelper } from "./HyperCoreMockHelper.sol";
import { HyperCoreWithdrawImplementation } from "../../../../contracts/periphery/counterfactual/HyperCoreWithdrawImplementation.sol";
import { WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { AdminWithdrawManager } from "../../../../contracts/periphery/counterfactual/AdminWithdrawManager.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { HyperCoreLib, ICoreWriter } from "../../../../contracts/libraries/HyperCoreLib.sol";

contract HyperCoreWithdrawImplementationTest is CounterfactualTestBase, HyperCoreMockHelper {
    HyperCoreWithdrawImplementation public coreWithdrawImpl;

    // USDC on HyperCore: index 0, asset-bridge address 0x2000…0000.
    uint64 constant USDC_CORE_INDEX = 0;
    address constant USDC_BRIDGE = 0x2000000000000000000000000000000000000000;
    uint64 constant AMOUNT_CORE = 384_824_037_300; // 3,848.240373 USDC in Core wei (8 decimals)

    function setUp() public {
        _setUpCore();
        _deployBeacon(_baseConfig());
        coreWithdrawImpl = new HyperCoreWithdrawImplementation();
        mockCoreWriter(true);
    }

    function _deployCloneWithCoreLeaf(
        bytes memory withdrawParams
    ) internal returns (address clone, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(address(coreWithdrawImpl), withdrawParams);
        leaves[1] = keccak256("padding");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        clone = factory.deploy(keccak256("salt"), root);
    }

    /// @dev The exact CoreWriter spotSend payload `HyperCoreLib.transferERC20SpotToSpot` emits.
    function _spotSendCall(address to, uint64 token, uint64 amount) internal pure returns (bytes memory) {
        return
            abi.encodeCall(
                ICoreWriter.sendRawAction,
                (abi.encodePacked(HyperCoreLib.SPOT_SEND_HEADER, abi.encode(to, token, amount)))
            );
    }

    // --- direct clone.execute tests ---

    function testCoreWithdrawByUser() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));
        vm.expectEmit(true, true, true, true);
        emit HyperCoreWithdrawImplementation.CoreWithdraw(USDC_CORE_INDEX, user, AMOUNT_CORE);

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, user, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testCoreWithdrawByAdmin() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        // Recipient is the committed user even when the admin executes.
        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, admin, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testRecipientIgnoresSubmitterTo() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);
        address attacker = makeAddr("attacker");

        // `to` in submitterData cannot redirect the Core send.
        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, attacker, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testUnauthorizedCallerReverts() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        vm.expectRevert(HyperCoreWithdrawImplementation.Unauthorized.selector);
        vm.prank(relayer); // not admin or user
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, relayer, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testTokenBelowBridgeRangeReverts() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        vm.expectRevert(stdError.arithmeticError);
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(address(0x1234), user, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testAmountOverUint64Reverts() public {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        vm.expectRevert();
        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, user, uint256(type(uint64).max) + 1),
            proof
        );
    }

    // --- AdminWithdrawManager paths (submitterData shape compatibility) ---

    function testDirectWithdrawViaManager() public {
        address directWithdrawer = makeAddr("directWithdrawer");
        AdminWithdrawManager manager = new AdminWithdrawManager(makeAddr("managerOwner"), directWithdrawer, signer);

        bytes memory wp = abi.encode(WithdrawParams({ admin: address(manager), user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));

        vm.prank(directWithdrawer);
        manager.directWithdraw(
            clone,
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, user, uint256(AMOUNT_CORE)),
            proof
        );
    }

    function testSignedWithdrawToUserViaManager() public {
        AdminWithdrawManager manager = new AdminWithdrawManager(
            makeAddr("managerOwner"),
            makeAddr("directWithdrawer"),
            signer
        );

        bytes memory wp = abi.encode(WithdrawParams({ admin: address(manager), user: user }));
        (address clone, bytes32[] memory proof) = _deployCloneWithCoreLeaf(wp);

        uint256 deadline = block.timestamp + 3600;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SignedWithdraw(address depositAddress,address token,uint256 amount,uint256 deadline)"),
                clone,
                USDC_BRIDGE,
                uint256(AMOUNT_CORE),
                deadline
            )
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256("AdminWithdrawManager"),
                keccak256("v1.0.0"),
                block.chainid,
                address(manager)
            )
        );
        bytes memory sig = _sign(signerPk, domainSeparator, structHash);

        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));

        manager.signedWithdrawToUser(
            clone,
            address(coreWithdrawImpl),
            wp,
            USDC_BRIDGE,
            uint256(AMOUNT_CORE),
            proof,
            deadline,
            sig
        );
    }

    // --- full recovery flow: root update adds the Core leaf to an existing tree ---

    /// @dev Mirrors the production recovery for a clone whose creation-time tree has no Core-withdraw
    ///      leaf: beacon owner publishes an upgrade tree for (clone, newRoot), anyone updates the root,
    ///      then the manager withdraws the Core balance to the committed user.
    function testRecoveryFlowViaRootUpdate() public {
        address directWithdrawer = makeAddr("directWithdrawer");
        AdminWithdrawManager manager = new AdminWithdrawManager(makeAddr("managerOwner"), directWithdrawer, signer);
        bytes memory wp = abi.encode(WithdrawParams({ admin: address(manager), user: user }));

        // Creation-time tree: EVM withdraw leaf only — Core balance unreachable.
        bytes32[] memory initialLeaves = new bytes32[](2);
        initialLeaves[0] = _leaf(address(withdrawImpl), wp);
        initialLeaves[1] = keccak256("padding");
        bytes32 initialRoot = merkle.getRoot(initialLeaves);
        address clone = factory.deploy(keccak256("incident-salt"), initialRoot);

        // New route tree: same leaves plus the Core-withdraw leaf.
        bytes32[] memory newLeaves = new bytes32[](3);
        newLeaves[0] = initialLeaves[0];
        newLeaves[1] = initialLeaves[1];
        newLeaves[2] = _leaf(address(coreWithdrawImpl), wp);
        bytes32 newRoot = merkle.getRoot(newLeaves);
        bytes32[] memory coreLeafProof = merkle.getProof(newLeaves, 2);

        // Beacon owner authorizes (clone → newRoot); anyone applies it.
        bytes32[] memory updateProof = _setUpgradeTree(clone, newRoot);
        CounterfactualDeposit(payable(clone)).updateRoot(newRoot, updateProof);
        assertEq(CounterfactualDeposit(payable(clone)).activeRoot(), newRoot);

        // Manager withdraws the Core balance to the committed user.
        vm.expectCall(CORE_WRITER_PRECOMPILE, _spotSendCall(user, USDC_CORE_INDEX, AMOUNT_CORE));
        vm.prank(directWithdrawer);
        manager.directWithdraw(
            clone,
            address(coreWithdrawImpl),
            wp,
            abi.encode(USDC_BRIDGE, user, uint256(AMOUNT_CORE)),
            coreLeafProof
        );
    }
}
