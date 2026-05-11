// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "murky/Merkle.sol";

import { CounterfactualDepositFactory } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactory.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    SpokePoolDepositParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTron } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTron.sol";
import { WithdrawImplementationTron } from "../../../../contracts/periphery/counterfactual/WithdrawImplementationTron.sol";
import { WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { TronTransferLib } from "../../../../contracts/libraries/TronTransferLib.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";

import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";

/// @notice Minimal SpokePool stand-in: pulls tokens via `transferFrom` (which is well-formed
///         on Tron USDT) so `execute()` can complete and we can observe the fee-payment branch.
contract MockSpokePool {
    function deposit(
        bytes32, // depositor
        bytes32, // recipient
        bytes32 inputToken,
        bytes32, // outputToken
        uint256 inputAmount,
        uint256, // outputAmount
        uint256, // destinationChainId
        bytes32, // exclusiveRelayer
        uint32, // quoteTimestamp
        uint32, // fillDeadline
        uint32, // exclusivityDeadline
        bytes calldata // message
    ) external payable {
        if (msg.value == 0) {
            address tokenAddr = address(uint160(uint256(inputToken)));
            // Bypass return-value check: the deposit pull uses transferFrom on the real SpokePool,
            // which returns true correctly on Tron USDT.
            (bool ok, ) = tokenAddr.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), inputAmount)
            );
            require(ok, "deposit pull failed");
        }
    }
}

contract Tron_CounterfactualTest is Test {
    Merkle merkle;
    CounterfactualDepositFactory factory;
    CounterfactualDeposit dispatcher;
    CounterfactualDepositSpokePoolTron spokePoolImpl;
    WithdrawImplementationTron withdrawImpl;
    MockSpokePool spokePool;
    MockTronUSDT usdt;

    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    uint256 signerPrivateKey = 0xA11CE;
    address signerAddr;

    SpokePoolDepositParams defaultParams;

    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    /// @dev EIP-712 domain inherited from `CounterfactualDepositSpokePool`.
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v1.0.0");

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function setUp() public {
        signerAddr = vm.addr(signerPrivateKey);

        usdt = new MockTronUSDT();
        merkle = new Merkle();
        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactory();
        dispatcher = new CounterfactualDeposit();
        spokePoolImpl = new CounterfactualDepositSpokePoolTron(address(spokePool), signerAddr, makeAddr("weth"));
        withdrawImpl = new WithdrawImplementationTron();

        usdt.mint(user, 1000e6);

        defaultParams = SpokePoolDepositParams({
            destinationChainId: 1,
            inputToken: bytes32(uint256(uint160(address(usdt)))),
            outputToken: bytes32(uint256(uint160(address(usdt)))),
            recipient: bytes32(uint256(uint160(makeAddr("recipient")))),
            message: "",
            stableExchangeRate: 1e18,
            maxFeeFixed: 1e6,
            maxFeeBps: 500,
            executionFee: 1e6
        });
    }

    function _computeLeaf(address implementation, bytes memory params) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(implementation, keccak256(params)))));
    }

    function _buildTreeAndDeploy(
        bytes memory depositParamsEncoded,
        bytes32 salt
    ) internal returns (address clone, bytes32[] memory depositProof, bytes32[] memory withdrawProof) {
        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _computeLeaf(address(spokePoolImpl), depositParamsEncoded);
        leaves[1] = _computeLeaf(address(withdrawImpl), wp);
        leaves[2] = keccak256("padding-a");
        leaves[3] = keccak256("padding-b");

        bytes32 root = merkle.getRoot(leaves);
        depositProof = merkle.getProof(leaves, 0);
        withdrawProof = merkle.getProof(leaves, 1);
        clone = factory.deploy(address(dispatcher), root, salt);
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signExecuteDeposit(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                inputAmount,
                outputAmount,
                bytes32(0),
                uint32(0),
                quoteTimestamp,
                fillDeadline,
                signatureDeadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodeSubmitterData(
        address clone,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline
    ) internal view returns (bytes memory) {
        bytes memory sig = _signExecuteDeposit(
            clone,
            inputAmount,
            outputAmount,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline
        );
        return
            abi.encode(
                SpokePoolSubmitterData({
                    inputAmount: inputAmount,
                    outputAmount: outputAmount,
                    exclusiveRelayer: bytes32(0),
                    exclusivityDeadline: 0,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: quoteTimestamp,
                    fillDeadline: fillDeadline,
                    signatureDeadline: signatureDeadline,
                    signature: sig
                })
            );
    }

    // ───────────────────── deposit-spoke-pool variant ─────────────────────

    function test_SpokePoolTron_PaysExecutionFeeOnTronUSDT() public {
        bytes32 salt = keccak256("tron-spoke-pool");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 expectedDeposit = inputAmount - defaultParams.executionFee;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address clone, bytes32[] memory proof, ) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            clone,
            inputAmount,
            outputAmount,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        // MockTronUSDT.transfer returns false but moves tokens — ensure clone still gets funded.
        usdt.transfer(clone, inputAmount);
        assertEq(usdt.balanceOf(clone), inputAmount, "clone should be funded");

        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);

        assertEq(usdt.balanceOf(relayer), defaultParams.executionFee, "relayer received execution fee");
        assertEq(usdt.balanceOf(address(spokePool)), expectedDeposit, "spoke pool received deposit");
        assertEq(usdt.balanceOf(clone), 0, "clone should be drained");
    }

    function test_SpokePoolTron_RevertsWhenFeeRecipientBlacklisted() public {
        bytes32 salt = keccak256("tron-spoke-pool-fail");
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint32 fillDeadline = uint32(block.timestamp) + 3600;

        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address clone, bytes32[] memory proof, ) = _buildTreeAndDeploy(paramsEncoded, salt);

        bytes memory submitterData = _encodeSubmitterData(
            clone,
            inputAmount,
            outputAmount,
            uint32(block.timestamp),
            fillDeadline,
            uint32(block.timestamp) + 3600
        );

        vm.prank(user);
        usdt.transfer(clone, inputAmount);

        // Force the fee transfer to revert.
        usdt.setBlacklisted(relayer, true);

        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(address(spokePoolImpl), paramsEncoded, submitterData, proof);
    }

    // ───────────────────── withdraw variant ─────────────────────

    function test_WithdrawTron_TransfersOnTronUSDT() public {
        bytes32 salt = keccak256("tron-withdraw");
        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address clone, , bytes32[] memory withdrawProof) = _buildTreeAndDeploy(paramsEncoded, salt);

        vm.prank(user);
        usdt.transfer(clone, 100e6);

        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        vm.prank(user);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(usdt), user, 100e6),
            withdrawProof
        );

        // user started with 1000e6, sent 100e6 to clone, now gets 100e6 back → 1000e6.
        assertEq(usdt.balanceOf(user), 1000e6);
        assertEq(usdt.balanceOf(clone), 0);
    }

    function test_WithdrawTron_RevertsWhenRecipientBlacklisted() public {
        bytes32 salt = keccak256("tron-withdraw-fail");
        bytes memory paramsEncoded = abi.encode(defaultParams);
        (address clone, , bytes32[] memory withdrawProof) = _buildTreeAndDeploy(paramsEncoded, salt);

        vm.prank(user);
        usdt.transfer(clone, 100e6);

        usdt.setBlacklisted(user, true);

        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));

        vm.prank(admin);
        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        ICounterfactualDeposit(clone).execute(
            address(withdrawImpl),
            wp,
            abi.encode(address(usdt), user, 100e6),
            withdrawProof
        );
    }
}
