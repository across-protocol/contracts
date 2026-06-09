// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SpokePoolRouteParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualDepositSpokePoolTr } from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePoolTr.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { WithdrawImplementationTron } from "../../../../contracts/periphery/counterfactual/WithdrawImplementationTron.sol";
import { WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { TronTransferLib } from "../../../../contracts/libraries/TronTransferLib.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { MockTronUSDT } from "../../../../contracts/test/MockTronUSDT.sol";

/// @notice Minimal SpokePool stand-in: pulls tokens via `transferFrom` so `execute()` reaches the
///         fee-payment branch under test.
contract MockSpokePool {
    function deposit(
        bytes32,
        bytes32,
        bytes32 inputToken,
        bytes32,
        uint256 inputAmount,
        uint256,
        uint256,
        bytes32,
        uint32,
        uint32,
        uint32,
        bytes calldata
    ) external payable {
        if (msg.value == 0) {
            (bool ok, ) = address(uint160(uint256(inputToken))).call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), inputAmount)
            );
            require(ok, "deposit pull failed");
        }
    }
}

/**
 * @notice Exercises the Tron leaf-impl variants (`CounterfactualDepositSpokePoolTr`,
 *         `WithdrawImplementationTron`). The proxy and dispatcher (`CounterfactualDeposit`) are
 *         chain-agnostic; only the leaf impls override transfer semantics (balance-delta check) to
 *         tolerate Tron USDT's non-standard `transfer`.
 */
contract Tron_CounterfactualTest is CounterfactualTestBase {
    CounterfactualDepositSpokePoolTr internal spokeImpl;
    WithdrawImplementationTron internal withdrawTron;
    MockSpokePool internal spokePool;
    MockTronUSDT internal usdt;
    address internal recipient;

    // EIP-712 domain name inherited from the mainline `CounterfactualDepositSpokePool`.
    string constant NAME = "CounterfactualDepositSpokePool";
    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    function setUp() public {
        _setUpCore();
        usdt = new MockTronUSDT();
        spokePool = new MockSpokePool();
        recipient = makeAddr("recipient");

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = makeAddr("weth");
        cfg.usdt = address(usdt);
        cfg.usdtSpokePoolMaxExecutionFee = 1e6;
        _deployBeacon(cfg);

        spokeImpl = new CounterfactualDepositSpokePoolTr();
        withdrawTron = new WithdrawImplementationTron();
        usdt.mint(user, 1000e6);
    }

    function _routeParams() internal view returns (SpokePoolRouteParams memory) {
        return
            SpokePoolRouteParams({
                inputTokenGetter: ICounterfactualBeacon.usdt.selector,
                destinationChainId: 1,
                outputToken: bytes32(uint256(uint160(address(usdt)))),
                recipient: bytes32(uint256(uint160(recipient))),
                message: "",
                checkStableExchangeRate: true,
                stableExchangeRate: 1e18,
                maxExecutionFeeGetter: ICounterfactualBeacon.usdtSpokePoolMaxExecutionFee.selector,
                maxFeeBps: 500
            });
    }

    /// @dev Tree: [spokePoolTr route, withdrawTron, pad, pad]. Returns (proxy, routeProof, withdrawProof).
    function _deploy(
        bytes memory route,
        bytes32 salt
    ) internal returns (address proxy, bytes32[] memory routeProof, bytes32[] memory withdrawProof) {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(spokeImpl), route);
        leaves[1] = _leaf(address(withdrawTron), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        routeProof = merkle.getProof(leaves, 0);
        withdrawProof = merkle.getProof(leaves, 1);
        proxy = factory.deploy(salt, root);
    }

    function _submitter(address proxy, bytes memory route) internal view returns (bytes memory) {
        uint256 inputAmount = 100e6;
        uint256 outputAmount = 98e6;
        uint256 executionFee = 1e6;
        uint32 ts = uint32(block.timestamp);
        uint32 deadline = ts + 3600;
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                proxy,
                keccak256(route),
                inputAmount,
                outputAmount,
                bytes32(0),
                uint32(0),
                ts,
                deadline,
                deadline,
                executionFee
            )
        );
        bytes memory sig = _sign(signerPk, _domainSeparator(NAME, proxy), structHash);
        return
            abi.encode(
                SpokePoolSubmitterData({
                    inputAmount: inputAmount,
                    outputAmount: outputAmount,
                    exclusiveRelayer: bytes32(0),
                    exclusivityDeadline: 0,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: ts,
                    fillDeadline: deadline,
                    signatureDeadline: deadline,
                    executionFee: executionFee,
                    signature: sig
                })
            );
    }

    // ───────────────────── deposit-spoke-pool variant ─────────────────────

    function test_SpokePoolTron_PaysExecutionFeeOnTronUSDT() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof, ) = _deploy(route, keccak256("tron-spoke"));
        bytes memory submitter = _submitter(proxy, route);

        vm.prank(user);
        usdt.transfer(proxy, 100e6); // returns false but moves tokens
        assertEq(usdt.balanceOf(proxy), 100e6);

        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(spokeImpl), route, submitter, proof);

        assertEq(usdt.balanceOf(relayer), 1e6, "relayer received execution fee");
        assertEq(usdt.balanceOf(address(spokePool)), 99e6, "spoke pool received deposit");
        assertEq(usdt.balanceOf(proxy), 0, "proxy drained");
    }

    function test_SpokePoolTron_RevertsWhenFeeRecipientBlacklisted() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof, ) = _deploy(route, keccak256("tron-spoke-fail"));
        bytes memory submitter = _submitter(proxy, route);

        vm.prank(user);
        usdt.transfer(proxy, 100e6);
        usdt.setBlacklisted(relayer, true);

        vm.prank(relayer);
        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        ICounterfactualDeposit(proxy).execute(address(spokeImpl), route, submitter, proof);
    }

    // ───────────────────── withdraw variant ─────────────────────

    function test_WithdrawTron_TransfersOnTronUSDT() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, , bytes32[] memory withdrawProof) = _deploy(route, keccak256("tron-withdraw"));

        vm.prank(user);
        usdt.transfer(proxy, 100e6);

        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        vm.prank(user);
        ICounterfactualDeposit(proxy).execute(
            address(withdrawTron),
            wp,
            abi.encode(address(usdt), user, 100e6),
            withdrawProof
        );

        assertEq(usdt.balanceOf(user), 1000e6); // 1000 - 100 + 100
        assertEq(usdt.balanceOf(proxy), 0);
    }

    function test_WithdrawTron_RevertsWhenRecipientBlacklisted() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, , bytes32[] memory withdrawProof) = _deploy(route, keccak256("tron-withdraw-fail"));

        vm.prank(user);
        usdt.transfer(proxy, 100e6);
        usdt.setBlacklisted(user, true);

        bytes memory wp = abi.encode(WithdrawParams({ admin: admin, user: user }));
        vm.prank(admin);
        vm.expectRevert(TronTransferLib.TronTransferCallReverted.selector);
        ICounterfactualDeposit(proxy).execute(
            address(withdrawTron),
            wp,
            abi.encode(address(usdt), user, 100e6),
            withdrawProof
        );
    }
}
