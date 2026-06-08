// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CounterfactualTestBase } from "./CounterfactualTestBase.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    CounterfactualDepositSpokePool,
    CounterfactualDepositSpokePoolUsdc,
    CounterfactualDepositSpokePoolNative,
    SpokePoolRouteParams,
    SpokePoolSubmitterData
} from "../../../../contracts/periphery/counterfactual/CounterfactualDepositSpokePool.sol";
import { CounterfactualImplementationBase } from "../../../../contracts/periphery/counterfactual/CounterfactualImplementationBase.sol";
import { CounterfactualChainConfig } from "../../../../contracts/periphery/counterfactual/CounterfactualBeacon.sol";
import { WithdrawParams } from "../../../../contracts/periphery/counterfactual/WithdrawImplementation.sol";
import { ICounterfactualDeposit } from "../../../../contracts/interfaces/ICounterfactualDeposit.sol";
import { CounterfactualDeposit } from "../../../../contracts/periphery/counterfactual/CounterfactualDeposit.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Mock SpokePool recording deposit args. Pulls ERC20 via transferFrom, or requires matching msg.value.
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
 * @notice Tests the chain-agnostic SpokePool counterfactual implementations. The input token is fixed by
 *         the concrete variant — `CounterfactualDepositSpokePoolUsdc` (ERC-20 USDC, resolved from
 *         `beacon.usdc()`) and `CounterfactualDepositSpokePoolNative` (native, wrapped via
 *         `beacon.wrappedNativeToken()`). The leaf carries no token and no source chain id; the SpokePool,
 *         wrapped native token and fee signer all come from the beacon. Each variant has a distinct EIP-712
 *         domain name so a fee signature is bound to one variant.
 */
contract CounterfactualDepositSpokePoolTest is CounterfactualTestBase {
    CounterfactualDepositSpokePoolUsdc internal usdcImpl;
    CounterfactualDepositSpokePoolNative internal nativeImpl;
    MockSpokePool internal spokePool;
    MintableERC20 internal token;
    address internal weth;
    address internal recipient;

    address constant NATIVE_ASSET = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    string constant NAME_USDC = "CounterfactualDepositSpokePoolUsdc";
    string constant NAME_NATIVE = "CounterfactualDepositSpokePoolNative";

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

        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = weth;
        cfg.usdc = address(token);
        _deployBeacon(cfg);

        usdcImpl = new CounterfactualDepositSpokePoolUsdc();
        nativeImpl = new CounterfactualDepositSpokePoolNative();
        token.mint(user, 1000e6);
    }

    function _routeParams() internal view returns (SpokePoolRouteParams memory) {
        return
            SpokePoolRouteParams({
                destinationChainId: 42161,
                outputToken: bytes32(uint256(uint160(address(token)))),
                recipient: bytes32(uint256(uint160(recipient))),
                message: "",
                checkStableExchangeRate: true,
                stableExchangeRate: 1e18,
                maxFeeFixed: 1e6,
                maxFeeBps: 500
            });
    }

    /// @dev Tree: [spokePool route, withdraw, pad, pad]. Deploy and return (proxy, routeProof).
    function _deploy(
        address impl,
        bytes memory routeEncoded,
        bytes32 salt
    ) internal returns (address proxy, bytes32[] memory proof) {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(impl, routeEncoded);
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
        string memory name,
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
        bytes memory sig = _sign(pk, _domainSeparator(name, proxy), structHash);
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
        address impl,
        address proxy,
        bytes memory routeEncoded,
        bytes memory submitter,
        bytes32[] memory proof
    ) internal {
        vm.prank(relayer);
        ICounterfactualDeposit(proxy).execute(impl, routeEncoded, submitter, proof);
    }

    // --- Happy paths ---

    function testErc20Deposit() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);

        _execute(address(usdcImpl), proxy, route, submitter, proof);

        assertEq(spokePool.lastMsgValue(), 0);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(address(token)))));
        assertEq(spokePool.lastOutputAmount(), e.outputAmount);
        assertEq(spokePool.lastDepositor(), bytes32(uint256(uint160(proxy))));
        assertEq(spokePool.lastRecipient(), bytes32(uint256(uint160(recipient))));
        assertEq(token.balanceOf(relayer), e.executionFee);
        assertEq(token.balanceOf(proxy), 0);
    }

    function testNativeDeposit() public {
        SpokePoolRouteParams memory rp = _routeParams();
        rp.maxFeeFixed = 0.01 ether;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(address(nativeImpl), route, bytes32(0));

        Exec memory e = _defaultExec();
        e.inputAmount = 1 ether;
        e.outputAmount = 0.98 ether;
        e.executionFee = 0.01 ether;
        bytes memory submitter = _signAndEncode(NAME_NATIVE, proxy, route, e, signerPk);

        vm.deal(proxy, e.inputAmount);
        _execute(address(nativeImpl), proxy, route, submitter, proof);

        assertEq(spokePool.lastMsgValue(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
        assertEq(spokePool.lastInputToken(), bytes32(uint256(uint160(weth))));
        assertEq(relayer.balance, e.executionFee);
    }

    function testDeployAndExecuteViaFactory() public {
        bytes memory route = abi.encode(_routeParams());
        bytes32 salt = keccak256("via-factory");
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(address(usdcImpl), route);
        leaves[1] = _leaf(address(withdrawImpl), abi.encode(WithdrawParams({ admin: admin, user: user })));
        leaves[2] = keccak256("pad-a");
        leaves[3] = keccak256("pad-b");
        bytes32 root = merkle.getRoot(leaves);
        bytes32[] memory proof = merkle.getProof(leaves, 0);
        address predicted = factory.predictAddress(salt, root);

        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(NAME_USDC, predicted, route, e, signerPk);

        vm.prank(user);
        token.transfer(predicted, e.inputAmount);

        bytes memory exec = abi.encodeCall(CounterfactualDeposit.execute, (address(usdcImpl), route, submitter, proof));
        vm.prank(relayer);
        address deployed = factory.deployAndExecute(salt, root, exec);

        assertEq(deployed, predicted);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
    }

    function testZeroExecutionFee() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        e.executionFee = 0;
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        _execute(address(usdcImpl), proxy, route, submitter, proof);

        assertEq(token.balanceOf(relayer), 0);
        assertEq(spokePool.lastInputAmount(), e.inputAmount);
    }

    // --- Fee gating ---

    function testExcessiveRelayerFeeReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        e.outputAmount = 92e6; // relayerFee = 99e6 - 92e6 = 7e6; +1e6 fee = 8e6 > maxFee 6e6
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        _execute(address(usdcImpl), proxy, route, submitter, proof);
    }

    function testCheckStableExchangeRateDisabledSkipsRelayerFee() public {
        // Low output that WOULD blow the max-fee under the rate check; with the flag off it passes.
        SpokePoolRouteParams memory rp = _routeParams();
        rp.checkStableExchangeRate = false;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));

        Exec memory e = _defaultExec();
        e.outputAmount = 50e6; // would imply a 49e6 relayer fee under the rate check
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        _execute(address(usdcImpl), proxy, route, submitter, proof);

        assertEq(spokePool.callCount(), 1);
        assertEq(spokePool.lastInputAmount(), e.inputAmount - e.executionFee);
    }

    function testCheckStableExchangeRateDisabledStillBoundsExecutionFee() public {
        SpokePoolRouteParams memory rp = _routeParams();
        rp.checkStableExchangeRate = false;
        bytes memory route = abi.encode(rp);
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));

        Exec memory e = _defaultExec();
        e.executionFee = 7e6; // > maxFee (1e6 + 5% of 100e6 = 6e6), even with relayerFee dropped
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.MaxFee.selector);
        _execute(address(usdcImpl), proxy, route, submitter, proof);
    }

    // --- Signature / replay ---

    function testInvalidSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, 0xBEEF); // wrong key

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        _execute(address(usdcImpl), proxy, route, submitter, proof);
    }

    function testExpiredSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(usdcImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        e.signatureDeadline = uint32(block.timestamp) + 100;
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.warp(block.timestamp + 101);
        vm.expectRevert(CounterfactualDepositSpokePool.SignatureExpired.selector);
        _execute(address(usdcImpl), proxy, route, submitter, proof);
    }

    function testCrossProxyReplayReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxyA, bytes32[] memory proofA) = _deploy(address(usdcImpl), route, keccak256("a"));
        (address proxyB, bytes32[] memory proofB) = _deploy(address(usdcImpl), route, keccak256("b"));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(NAME_USDC, proxyA, route, e, signerPk); // signed for A

        vm.prank(user);
        token.transfer(proxyA, e.inputAmount);
        vm.prank(user);
        token.transfer(proxyB, e.inputAmount);

        vm.prank(relayer);
        ICounterfactualDeposit(proxyA).execute(address(usdcImpl), route, submitter, proofA);

        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        vm.prank(relayer);
        ICounterfactualDeposit(proxyB).execute(address(usdcImpl), route, submitter, proofB);
    }

    /// @dev A signature carrying the USDC variant's domain name does not verify against the native variant,
    ///      even with identical route params and proxy — the per-variant EIP-712 name binds it.
    function testCrossVariantSignatureReverts() public {
        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(nativeImpl), route, bytes32(0));
        Exec memory e = _defaultExec();
        // Sign with the USDC variant's domain name but execute the native variant.
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.deal(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualDepositSpokePool.InvalidSignature.selector);
        _execute(address(nativeImpl), proxy, route, submitter, proof);
    }

    /// @dev Executing a route whose input token is unset on this chain's beacon reverts cleanly.
    function testRouteNotConfiguredReverts() public {
        // Redeploy the beacon with USDC unset (spokePool still set).
        CounterfactualChainConfig memory cfg = _baseConfig();
        cfg.spokePool = address(spokePool);
        cfg.wrappedNativeToken = weth;
        _deployBeacon(cfg);
        CounterfactualDepositSpokePoolUsdc impl = new CounterfactualDepositSpokePoolUsdc();

        bytes memory route = abi.encode(_routeParams());
        (address proxy, bytes32[] memory proof) = _deploy(address(impl), route, bytes32(0));
        Exec memory e = _defaultExec();
        bytes memory submitter = _signAndEncode(NAME_USDC, proxy, route, e, signerPk);

        vm.prank(user);
        token.transfer(proxy, e.inputAmount);
        vm.expectRevert(CounterfactualImplementationBase.RouteNotConfigured.selector);
        _execute(address(impl), proxy, route, submitter, proof);
    }
}
