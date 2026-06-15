// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    CounterfactualDepositSpokePool,
    SpokePoolRouteParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualImplementationBase } from "../../../../contracts/periphery/counterfactual/CounterfactualImplementationBase.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { ICounterfactualBeacon } from "../../../../contracts/interfaces/ICounterfactualBeacon.sol";
import { WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock SpokePool: records deposit args; pulls ERC20 via transferFrom, else requires matching msg.value.
contract MockSpokePool {
    using SafeERC20 for IERC20;

    uint256 public callCount;
    bytes32 public lastDepositor;
    bytes32 public lastRecipient;
    bytes32 public lastInputToken;
    uint256 public lastInputAmount;
    uint256 public lastOutputAmount;
    uint256 public lastMsgValue;
    bytes public lastMessage;

    function deposit(
        bytes32 depositor,
        bytes32 recipient,
        bytes32 inputToken,
        bytes32,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256,
        bytes32,
        uint32,
        uint32,
        uint32,
        bytes calldata message
    ) external payable {
        if (msg.value > 0) {
            require(msg.value == inputAmount, "msg.value mismatch");
        } else {
            IERC20(address(uint160(uint256(inputToken)))).safeTransferFrom(msg.sender, address(this), inputAmount);
        }
        lastDepositor = depositor;
        lastRecipient = recipient;
        lastInputToken = inputToken;
        lastInputAmount = inputAmount;
        lastOutputAmount = outputAmount;
        lastMsgValue = msg.value;
        lastMessage = message;
        callCount++;
    }
}

/**
 * @notice Tests the token-agnostic SpokePool counterfactual implementation. The leaf carries the beacon
 *         getter selector for its input token (`inputTokenGetter`); native vs ERC-20 is decided by the
 *         resolved value (`NATIVE_SENTINEL` ⇒ native, wrapped via `beacon.wrappedNativeToken()`; else
 *         ERC-20). SpokePool and fee signer come from the beacon. One implementation handles every token,
 *         so the single EIP-712 domain plus the token selector in `routeParamsHash` binds a fee signature
 *         to one token.
 */
contract CounterfactualDepositSpokePoolTest is CounterfactualTestBase {
    CounterfactualDepositSpokePool internal spokeImpl;
    MockSpokePool internal spokePool;
    MintableERC20 internal token; // resolved via beacon.usdc()
    MintableERC20 internal altToken; // resolved via beacon.usdt()
    address internal weth;
    address internal recipient;

    bytes4 constant USDC_GETTER = ICounterfactualBeacon.usdc.selector;
    bytes4 constant USDT_GETTER = ICounterfactualBeacon.usdt.selector;
    bytes4 constant NATIVE_GETTER = ICounterfactualBeacon.nativeToken.selector;
    /// @dev Mirrors `CounterfactualDepositSpokePool.NATIVE_SENTINEL`; redeclared because Solidity can't
    ///      dot-access a contract's public constant in a struct-field assignment.
    address constant NATIVE_SENTINEL = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    string constant NAME = "CounterfactualDepositSpokePool";

    bytes32 constant EXECUTE_DEPOSIT_TYPEHASH =
        keccak256(
            "ExecuteDeposit(address clone,bytes32 routeParamsHash,uint256 inputAmount,uint256 outputAmount,bytes32 exclusiveRelayer,uint32 exclusivityDeadline,uint32 quoteTimestamp,uint32 fillDeadline,uint32 signatureDeadline,uint256 executionFee)"
        );

    function setUp() public {
        _setUpCore();
        spokePool = new MockSpokePool();
        weth = makeAddr("weth");
        recipient = makeAddr("recipient");
        token = new MintableERC20("USDC", "USDC", 6);
        altToken = new MintableERC20("USDT", "USDT", 6);

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = weth;
        cfg.nativeToken = NATIVE_SENTINEL;
        cfg.usdc = address(token);
        cfg.usdt = address(altToken);
        cfg.usdcSpokePoolMaxExecutionFee = 1e6;
        cfg.usdtSpokePoolMaxExecutionFee = 1e6;
        cfg.wethSpokePoolMaxExecutionFee = 0.01 ether;
        _deployBeacon(cfg);

        spokeImpl = new CounterfactualDepositSpokePool();
        token.mint(user, 1000e6);
        altToken.mint(user, 1000e6);
    }

    function _routeParams(bytes4 inputTokenGetter) internal view returns (SpokePoolRouteParams memory) {
        // The fixed fee cap getter pairs with the input token (USDC/USDT/native→WETH).
        bytes4 maxFeeGetter = inputTokenGetter == USDC_GETTER
            ? ICounterfactualBeacon.usdcSpokePoolMaxExecutionFee.selector
            : inputTokenGetter == USDT_GETTER
                ? ICounterfactualBeacon.usdtSpokePoolMaxExecutionFee.selector
                : ICounterfactualBeacon.wethSpokePoolMaxExecutionFee.selector;
        return
            SpokePoolRouteParams({
                inputTokenGetter: inputTokenGetter,
                destinationChainId: 42161,
                outputToken: bytes32(uint256(uint160(address(token)))),
                recipient: bytes32(uint256(uint160(recipient))),
                message: "",
                checkStableExchangeRate: true,
                stableExchangeRate: 1e18,
                maxExecutionFeeGetter: maxFeeGetter,
                maxFeeBps: 500
            });
    }

    /// @dev Tree: [spokePool route, withdraw, pad, pad]. Deploy and return (proxy, routeProof).
    function _deploy(bytes memory routeEncoded, bytes32 salt) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(spokeImpl), routeEncoded);
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        proof = merkle.getProof(leaves, 0);
        proxy = factory.deploy(salt, root);
    }

    struct Exec {
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 executionFee;
        bytes32 exclusiveRelayer;
        uint32 exclusivityDeadline;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 signatureDeadline;
    }

    function _defaultExec() internal view returns (Exec memory) {
        return
            Exec({
                inputAmount: 100e6,
                outputAmount: 98e6,
                executionFee: 1e6,
                exclusiveRelayer: bytes32(0),
                exclusivityDeadline: 0,
                quoteTimestamp: uint32(block.timestamp),
                fillDeadline: uint32(block.timestamp) + 3600,
                signatureDeadline: uint32(block.timestamp) + 3600
            });
    }

    function _signAndEncode(
        address proxy,
        bytes memory routeEncoded,
        Exec memory e,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                EXECUTE_DEPOSIT_TYPEHASH,
                proxy,
                keccak256(routeEncoded),
                e.inputAmount,
                e.outputAmount,
                e.exclusiveRelayer,
                e.exclusivityDeadline,
                e.quoteTimestamp,
                e.fillDeadline,
                e.signatureDeadline,
                e.executionFee
            )
        );
        bytes memory sig = _sign(pk, _domainSeparator(NAME, proxy), structHash);
        return
            abi.encode(
                SpokePoolSubmitterData({
                    inputAmount: e.inputAmount,
                    outputAmount: e.outputAmount,
                    exclusiveRelayer: e.exclusiveRelayer,
                    exclusivityDeadline: e.exclusivityDeadline,
                    executionFeeRecipient: relayer,
                    quoteTimestamp: e.quoteTimestamp,
                    fillDeadline: e.fillDeadline,
                    signatureDeadline: e.signatureDeadline,
                    executionFee: e.executionFee,
                    signature: sig
                })
            );
    }

    function _execute(
        address proxy,
        bytes memory routeEncoded,
        bytes memory submitter,
        bytes32[] memory proof
    ) internal {
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(spokeImpl), routeEncoded, submitter, proof);
    }

    // --- Happy paths ---

    function testErc20Deposit() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);

        _execute(proxy, route, submitter, proof);

        assertEq(spokePool.lastMsgValue(), 0);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(address(token)))));
        assertEq(spokePool.lastOutputAmount(), e.outputAmount);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(proxy))));
        assertEq(spokePool.lastRecipient(), bytes32(uint256(uint160(recipient))));
        assertEq(token.balanceOf(relayer), e.executionFee);
        assertEq(token.balanceOf(proxy), 0);
    }

    /// @dev Any beacon-registered token works through the same implementation, selected by its getter.
    function testArbitraryTokenViaGetter() public {
        bytes memory route = abi.encode(_routeParams(USDT_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        altToken.transfer(proxy, e.inputAmount);

        _execute(proxy, route, submitter, proof);

        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(address(altToken)))));
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
        assertEq(altToken.balanceOf(relayer), e.executionFee);
        assertEq(altToken.balanceOf(proxy), 0);
    }

    function testNativeDeposit() public {
        bytes memory route = abi.encode(_routeParams(NATIVE_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));

        Exec memory e = _defaultExec();
        e.inputAmount = 1 ether;
        e.outputAmount = 0.98 ether;
        e.executionFee = 0.01 ether;
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.deal(proxy, e.inputAmount);
        _execute(proxy, route, submitter, proof);

        assertEq(spokePool.lastMsgValue(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(weth))));
        assertEq(relayer.balance, e.executionFee);
    }

    /// @dev When `beacon.nativeToken()` resolves to an ERC-20 (not the sentinel), the same leaf naming
    ///      `nativeToken.selector` must take the ERC-20 path (transferFrom, no msg.value) — behavior is
    ///      decided by the resolved value, not the selector.
    function testNativeGetterResolvingToErc20UsesErc20Path() public {
        // Redeploy with `nativeToken` set to an ERC-20 instead of the sentinel.
        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = weth;
        cfg.nativeToken = address(token); // ERC-20 stand-in for "native"
        cfg.usdc = address(token);
        cfg.usdt = address(altToken);
        cfg.usdcSpokePoolMaxExecutionFee = 1e6;
        cfg.usdtSpokePoolMaxExecutionFee = 1e6;
        cfg.wethSpokePoolMaxExecutionFee = 0.01 ether;
        _deployBeacon(cfg);
        CounterfactualDepositSpokePool impl = new CounterfactualDepositSpokePool();

        bytes memory route = abi.encode(_routeParams(NATIVE_GETTER));
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(impl), route);
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);
        address proxy = factory.deploy(bytes32(0), root);

        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);

        bytes memory exec = abi.encodeCall(CounterfactualDeposit.execute, (address(impl), route, submitter, proof));
        vm.prank(relayer);
        (bool ok, ) = proxy.call(exec);
        assertTrue(ok);

        // ERC-20 path: SpokePool got the ERC-20 (not WETH), no msg.value, fee in ERC-20.
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(address(token)))));
        assertEq(spokePool.lastMsgValue(), 0);
        assertEq(token.balanceOf(relayer), e.executionFee);
        assertEq(token.balanceOf(proxy), 0);
    }

    function testDeployAndExecuteViaFactory() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        bytes32 salt = keccak256("via-factory");
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(spokeImpl), route);
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);
        address predicted = factory.predictAddress(salt, root);

        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(predicted, route, e, signerPk);

        vm.prank(user);
        token.transfer(predicted, e.inputAmount);

        bytes memory exec = abi.encodeCall(
            CounterfactualDeposit.execute,
            (address(spokeImpl), route, submitter, proof)
        );
        vm.prank(relayer);
        address deployed = factory.deployAndExecute(salt, root, exec);

        assertEq(deployed, predicted);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
    }

    function testZeroExecutionFee() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        e.executionFee = 0;
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        _execute(proxy, route, submitter, proof);

        assertEq(token.balanceOf(relayer), 0);
        assertEq(spokePool.lastInputAmount(), e.inputAmount);
    }

    // --- Fee gating ---

    function testExcessiveRelayerFeeReverts() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        e.outputAmount = 92e6; // relayerFee 7e6 + 1e6 execFee = 8e6 > maxFee 6e6
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        _execute(proxy, route, submitter, proof);
    }

    function testCheckStableExchangeRateDisabledSkipsRelayerFee() public {
        // Low output that would blow the max-fee under the rate check, but the flag is off.
        SpokePoolRouteParams memory rp = _routeParams(USDC_GETTER);
        rp.checkStableExchangeRate = false;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));

        Exec memory e = _defaultExec();
        e.outputAmount = 50e6; // implies a 49e6 relayer fee under the rate check
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        _execute(proxy, route, submitter, proof);

        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
    }

    function testCheckStableExchangeRateDisabledStillBoundsExecutionFee() public {
        SpokePoolRouteParams memory rp = _routeParams(USDC_GETTER);
        rp.checkStableExchangeRate = false;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));

        Exec memory e = _defaultExec();
        e.executionFee = 7e6; // > maxFee 6e6 even with relayerFee dropped
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        _execute(proxy, route, submitter, proof);
    }

    // --- Signature / replay ---

    function testInvalidSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxy, route, e, 0xBEEF); // wrong key

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        _execute(proxy, route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxy, bytes32[] memory proof) = _deploy(route, bytes32(0));
        Exec memory e = _defaultExec();
        e.signatureDeadline = uint32(block.timestamp) + 100;
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.warp(block.timestamp + 101);
        vm.expectRevert(CounterfactualDepositSpokePool.SignatureExpired.selector);
        _execute(proxy, route, submitter, proof);
    }

    function testCrossProxyReplayReverts() public {
        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        (address proxyA, bytes32[] memory proofA) = _deploy(route, keccak256("a"));
        (address proxyB, bytes32[] memory proofB) = _deploy(route, keccak256("b"));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxyA, route, e, signerPk); // signed for proxyA

        vm.prank(user);
        token.transfer(proxyA, e.inputAmount);
        vm.prank(user);
        token.transfer(proxyB, e.inputAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxyA).execute(address(spokeImpl), route, submitter, proofA);

        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxyB).execute(address(spokeImpl), route, submitter, proofB);
    }

    /// @dev A USDC-route signature doesn't validate a USDT route on the same proxy: the input token getter
    ///      is part of `routeParamsHash`, so the routes have different signed digests.
    function testCrossTokenSignatureReverts() public {
        bytes memory usdcRoute = abi.encode(_routeParams(USDC_GETTER));
        bytes memory usdtRoute = abi.encode(_routeParams(USDT_GETTER));

        // Both routes in one tree for the same proxy.
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(spokeImpl), usdcRoute);
        leaves[1] = _leaf(address(spokeImpl), usdtRoute);
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory usdtProof = merkle.getProof(leaves, 1);
        address proxy = factory.deploy(bytes32(0), root);

        Exec memory e = _defaultExec();
        // Sign for USDC, execute USDT.
        bytes memory submitter = _signAndEncode(proxy, usdcRoute, e, signerPk);

        vm.prank(user);
        altToken.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(spokeImpl), usdtRoute, submitter, usdtProof);
    }

    /// @dev A route whose input-token getter is unset on the beacon reverts cleanly.
    function testRouteNotConfiguredReverts() public {
        // Redeploy with USDC unset (spokePool still set).
        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = weth;
        _deployBeacon(cfg);
        CounterfactualDepositSpokePool impl = new CounterfactualDepositSpokePool();

        bytes memory route = abi.encode(_routeParams(USDC_GETTER));
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(impl), route);
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);
        address proxy = factory.deploy(bytes32(0), root);

        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualImplementationBase.RouteNotConfigured.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(address(impl), route, submitter, proof);
    }
}
