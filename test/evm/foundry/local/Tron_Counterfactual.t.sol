// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { CounterfactualDepositFactoryTron } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositFactoryTron.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import {
    SpokePoolRouteParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTr } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTr.sol";
import { WithdrawImplementationTron } from "../../../../contracts/periphery/counterfactual/WithdrawImplementationTron.sol";
import { RoutePolicy } from "../../../../contracts/periphery/counterfactual/RoutePolicy.sol";
import { deployRoutePolicy } from "../utils/RoutePolicyTestHelper.sol";
import { TronTransferLib } from "../../../../contracts/libraries/TronTransferLib.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CloneArgs } from "../../../../contracts/periphery/counterfactual/CounterfactualCloneArgs.sol";
import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";

/// @notice Minimal SpokePool stand-in: pulls tokens via `transferFrom` (well-formed on Tron USDT).
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
            (bool ok, ) = tokenAddr.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), inputAmount)
            );
            require(ok, "deposit pull failed");
        }
    }
}

contract Tron_CounterfactualTest is Test {
    CounterfactualDepositFactoryTron factory;
    CounterfactualDeposit dispatcher;
    CounterfactualDepositSpokePoolTr spokePoolImpl;
    WithdrawImplementationTron withdrawImpl;
    RoutePolicy policy;
    MockSpokePool spokePool;
    MockTronUSDT usdt;

    address admin = makeAddr("admin");
    address user = makeAddr("user");
    address relayer = makeAddr("relayer");
    address policyOwner = makeAddr("policyOwner");
    uint256 signerPrivateKey = 0xA11CE;
    address signerAddr;
    bytes32 recipient;

    SpokePoolRouteParams defaultParams;

    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    // Inherits the parent's EIP-712 domain.
    bytes32 constant NAME_HASH = keccak256("CounterfactualDepositSpokePool");
    bytes32 constant VERSION_HASH = keccak256("v2.0.0");

    uint256 constant DESTINATION_CHAIN_ID = 1;

    function setUp() public {
        signerAddr = vm.addr(signerPrivateKey);
        recipient = bytes32(uint256(uint160(makeAddr("recipient"))));

        usdt = new MockTronUSDT();
        spokePool = new MockSpokePool();
        factory = new CounterfactualDepositFactoryTron();
        withdrawImpl = new WithdrawImplementationTron();
        dispatcher = new CounterfactualDeposit();
        spokePoolImpl = new CounterfactualDepositSpokePoolTr(address(spokePool), signerAddr, makeAddr("weth"));
        policy = deployRoutePolicy(policyOwner, bytes32(0));

        usdt.mint(user, 1000e6);

        defaultParams = SpokePoolRouteParams({
            inputToken: bytes32(uint256(uint160(address(usdt)))),
            message: "",
            stableExchangeRate: 1e18,
            maxFeeFixed: 1e6,
            maxFeeBps: 500
        });
    }

    function _cloneArgs() internal view returns (CloneArgs memory) {
        return
            CloneArgs({
                outputToken: bytes32(uint256(uint160(address(usdt)))),
                destinationChainId: DESTINATION_CHAIN_ID,
                recipient: recipient,
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

    function _setRoot(bytes memory routeParams) internal returns (bytes32[] memory proof) {
        bytes32 outputToken = bytes32(uint256(uint160(address(usdt))));
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _computeLeaf(address(spokePoolImpl), outputToken, DESTINATION_CHAIN_ID, routeParams);
        leaves[1] = keccak256("padding");
        bytes32 a = leaves[0];
        bytes32 b = leaves[1];
        bytes32 root = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        proof = new bytes32[](1);
        proof[0] = leaves[1];
        vm.prank(policyOwner);
        policy.updateRoot(root);
    }

    function _domainSeparator(address clone) internal view returns (bytes32) {
        return keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, clone));
    }

    function _signExecute(
        address clone,
        bytes32 routeParamsHash,
        uint256 inputAmount,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 signatureDeadline,
        uint256 executionFee
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                clone,
                routeParamsHash,
                inputAmount,
                outputAmount,
                bytes32(0),
                uint32(0),
                quoteTimestamp,
                fillDeadline,
                signatureDeadline,
                executionFee
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(clone), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _submitterData(
        address clone,
        bytes memory routeParamsEncoded,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 executionFee
    ) internal view returns (bytes memory) {
        uint32 quoteTimestamp = uint32(block.timestamp);
        uint32 fillDeadline = uint32(block.timestamp) + 3600;
        uint32 signatureDeadline = uint32(block.timestamp) + 3600;
        bytes memory sig = _signExecute(
            clone,
            keccak256(routeParamsEncoded),
            inputAmount,
            outputAmount,
            quoteTimestamp,
            fillDeadline,
            signatureDeadline,
            executionFee
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
                    executionFee: executionFee,
                    counterfactualSignature: sig
                })
            );
    }

    // --- Tron-flavored SpokePool fee transfer ---

    function test_SpokePoolTron_PaysExecutionFeeOnTronUSDT() public {
        bytes memory routeParamsEncoded = abi.encode(defaultParams);
        bytes32[] memory proof = _setRoot(routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("tron-spoke-pool"));

        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 executionFee = 1e6;

        vm.prank(user);
        // MockTronUSDT.transfer returns false but moves tokens.
        usdt.transfer(clone, inputAmount);
        assertEq(usdt.balanceOf(clone), inputAmount);

        bytes memory submitterData = _submitterData(clone, routeParamsEncoded, inputAmount, outputAmount, executionFee);

        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );

        assertEq(usdt.balanceOf(relayer), executionFee);
        assertEq(usdt.balanceOf(address(spokePool)), inputAmount - executionFee);
        assertEq(usdt.balanceOf(clone), 0);
    }

    function test_SpokePoolTron_RevertsWhenFeeRecipientBlacklisted() public {
        bytes memory routeParamsEncoded = abi.encode(defaultParams);
        bytes32[] memory proof = _setRoot(routeParamsEncoded);
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("tron-spoke-pool-fail"));

        vm.prank(user);
        usdt.transfer(clone, 100e6);
        usdt.setBlacklisted(relayer, true);

        bytes memory submitterData = _submitterData(clone, routeParamsEncoded, 100e6, 98e6, 1e6);

        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(spokePoolImpl),
            routeParamsEncoded,
            submitterData,
            proof
        );
    }

    // --- Tron-flavored withdraw escape ---

    function test_WithdrawTron_TransfersOnTronUSDT() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("tron-withdraw"));

        vm.prank(user);
        usdt.transfer(clone, 100e6);

        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(usdt), admin, uint256(100e6)),
            new bytes32[](0)
        );

        assertEq(usdt.balanceOf(admin), 100e6);
        assertEq(usdt.balanceOf(clone), 0);
    }

    function test_WithdrawTron_RevertsWhenRecipientBlacklisted() public {
        address clone = factory.deploy(address(dispatcher), _cloneArgs(), keccak256("tron-withdraw-fail"));

        vm.prank(user);
        usdt.transfer(clone, 100e6);
        usdt.setBlacklisted(admin, true);

        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        vm.prank(admin);
        ICounterfactualDeposit(clone).execute(
            _cloneArgs(),
            address(withdrawImpl),
            "",
            abi.encode(address(usdt), admin, uint256(100e6)),
            new bytes32[](0)
        );
    }
}
