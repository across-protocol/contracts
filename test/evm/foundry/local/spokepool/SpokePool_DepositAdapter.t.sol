// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MockGateway } from "../../../../../contracts/test/MockGateway.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ExpandedERC20 } from "../../../../../contracts/external/uma/core/contracts/common/implementation/ExpandedERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";
import { V5SpokePoolInterface } from "../../../../../contracts/interfaces/V5SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";

/// @notice Tests for the Executor-driven V5 deposit path: `adapterExecuteAcrossV5` with the `Deposit` action.
/// @dev The SpokePool acts as a source-side adapter inside a Gateway execution: input tokens are pulled from
/// `msg.sender` (the committed Executor), the deposit id is derived from the live Gateway context, and the
/// deposit message is stamped `V5_MAGIC_PREFIX || dstStepId`. Submitters may adjust a whitelisted subset of
/// the committed parameters just-in-time, subject to `paramModificationRules`.
contract SpokePoolDepositAdapterTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    MockGateway public gateway;
    WETH9 public weth;
    ExpandedERC20 public erc20; // source/input token
    ExpandedERC20 public destErc20; // destination/output token (only used as a label)

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
    address public submitter; // the Gateway's current submitter (namespaces the deposit id)
    address public executor; // the committed Executor: the only allowed caller, and the deposit's funder
    address public depositor;
    address public recipient;

    uint256 public authorityKey;
    address public authority; // signs JIT modification sets when `paramModificationRules` names it

    bytes32 public constant STEP_ID = keccak256("step-1");
    bytes32 public constant PATH_ID = keccak256("path-1");
    bytes32 public constant DST_STEP_ID = keccak256("dst-step-1");

    uint256 public constant AMOUNT_TO_SEED = 1500e18;
    uint256 public constant AMOUNT = 100e18;
    uint256 public constant DEPOSIT_NONCE = 42;
    uint256 public constant SOURCE_CHAIN_ID = 666;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;

    // Bit flags packed into the high 12 bytes of `V5DepositInput.paramModificationRules` (mirrors SpokePool's
    // internal MOD_FLAG_* constants).
    uint256 public constant FLAG_AMOUNT_OUT = 1 << 0;
    uint256 public constant FLAG_EXCLUSIVE_RELAYER = 1 << 1;
    uint256 public constant FLAG_EXCLUSIVITY = 1 << 2;

    event FundsDeposited(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint256 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 indexed depositor,
        bytes32 recipient,
        bytes32 exclusiveRelayer,
        bytes message
    );

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        submitter = makeAddr("submitter");
        executor = makeAddr("executor");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        (authority, authorityKey) = makeAddrAndKey("authority");

        weth = new WETH9();

        erc20 = new ExpandedERC20("USD Coin", "USDC", 18);
        erc20.addMember(1, address(this));
        destErc20 = new ExpandedERC20("L2 USD Coin", "L2 USDC", 18);
        destErc20.addMember(1, address(this));

        // Gateway must be wired in before the implementation is deployed (it's an immutable).
        gateway = new MockGateway();
        gateway.setSubmitter(submitter);
        gateway.setExecutor(executor);
        gateway.setStepId(STEP_ID);
        gateway.setPathId(PATH_ID);

        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth), address(gateway));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
            )
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(SOURCE_CHAIN_ID);
        vm.stopPrank();

        // The Executor funds adapter deposits, so it holds + approves the input token.
        erc20.mint(executor, AMOUNT_TO_SEED);
        vm.prank(executor);
        erc20.approve(address(spokePool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultInput() internal view returns (V5SpokePoolInterface.V5DepositInput memory) {
        return
            V5SpokePoolInterface.V5DepositInput({
                depositor: depositor.toBytes32(),
                recipient: recipient.toBytes32(),
                inputToken: address(erc20).toBytes32(),
                outputToken: address(destErc20).toBytes32(),
                inputAmount: AMOUNT,
                outputAmount: AMOUNT,
                destinationChainId: DESTINATION_CHAIN_ID,
                exclusiveRelayer: bytes32(0),
                depositNonce: DEPOSIT_NONCE,
                quoteTimestamp: uint32(spokePool.getCurrentTime()),
                fillDeadline: uint32(spokePool.getCurrentTime()) + 1000,
                exclusivityParameter: 0,
                dstStepId: DST_STEP_ID,
                paramModificationRules: bytes32(0)
            });
    }

    function _defaultJit() internal pure returns (V5SpokePoolInterface.V5DepositJit memory) {
        return
            V5SpokePoolInterface.V5DepositJit({
                newOutputAmount: 0,
                newExclusiveRelayer: bytes32(0),
                newExclusivityParameter: 0,
                signature: ""
            });
    }

    /// @dev Encodes the adapter `input` for a deposit: the 1-byte `Deposit` action prefix followed by the
    /// ABI-encoded input.
    function _depositPayload(V5SpokePoolInterface.V5DepositInput memory input) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(V5SpokePoolInterface.V5AdapterAction.Deposit)), abi.encode(input));
    }

    function _adapterDeposit(
        V5SpokePoolInterface.V5DepositInput memory input,
        V5SpokePoolInterface.V5DepositJit memory jit
    ) internal {
        vm.prank(executor);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }

    /// @dev The deposit id the SpokePool derives from the live Gateway context: namespaced by the submitter and
    /// differentiated by (pathId, depositNonce).
    function _expectedDepositId() internal view returns (uint256) {
        return
            spokePool.getUnsafeDepositId(
                submitter,
                depositor.toBytes32(),
                uint256(keccak256(abi.encodePacked(PATH_ID, DEPOSIT_NONCE)))
            );
    }

    /// @dev The message stamped onto every V5 deposit: the V5 header followed by the committed destination
    /// step id.
    function _v5DepositMessage() internal view returns (bytes memory) {
        return abi.encodePacked(spokePool.V5_MAGIC_PREFIX(), DST_STEP_ID);
    }

    /// @dev Packs (flags, authority) into `paramModificationRules`.
    function _rules(uint256 flags, address authority_) internal pure returns (bytes32) {
        return bytes32((flags << 160) | uint256(uint160(authority_)));
    }

    /// @dev Authority signature over the JIT modification set, matching `_resolveDynamicParams`'s digest.
    function _signModifications(
        V5SpokePoolInterface.V5DepositJit memory jit,
        uint256 signerKey
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                spokePool.VERSIONED_AUCTION_NAMEHASH(),
                address(gateway),
                PATH_ID,
                DEPOSIT_NONCE,
                jit.newOutputAmount,
                jit.newExclusiveRelayer,
                jit.newExclusivityParameter
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /*//////////////////////////////////////////////////////////////
                        adapter deposit
    //////////////////////////////////////////////////////////////*/

    function testHappyPathPullsFromCallerAndEmitsV5TaggedDeposit() public {
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();

        uint256 executorBefore = erc20.balanceOf(executor);

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            input.inputToken,
            input.outputToken,
            input.inputAmount,
            input.outputAmount,
            input.destinationChainId,
            _expectedDepositId(),
            input.quoteTimestamp,
            input.fillDeadline,
            0, // no exclusivity
            input.depositor,
            input.recipient,
            input.exclusiveRelayer,
            _v5DepositMessage()
        );
        _adapterDeposit(input, jit);

        // Input tokens come from the caller (Executor), locked in the SpokePool.
        assertEq(erc20.balanceOf(executor), executorBefore - AMOUNT);
        assertEq(erc20.balanceOf(address(spokePool)), AMOUNT);
    }

    function testDepositIdsDifferPerNonceAndSubmitter() public {
        // Two deposits committed in one path execution are differentiated by their committed nonce; a different
        // submitter executing the same leaf produces a different id space.
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        uint256 idNonce42 = _expectedDepositId();

        input.depositNonce = DEPOSIT_NONCE + 1;
        uint256 idNonce43 = spokePool.getUnsafeDepositId(
            submitter,
            input.depositor,
            uint256(keccak256(abi.encodePacked(PATH_ID, input.depositNonce)))
        );
        assertNotEq(idNonce42, idNonce43);

        uint256 idOtherSubmitter = spokePool.getUnsafeDepositId(
            makeAddr("otherSubmitter"),
            input.depositor,
            uint256(keccak256(abi.encodePacked(PATH_ID, input.depositNonce)))
        );
        assertNotEq(idNonce43, idOtherSubmitter);
    }

    function testRevertsWhenCallerIsNotCurrentExecutor() public {
        address stray = makeAddr("strayCaller");
        erc20.mint(stray, AMOUNT_TO_SEED);
        vm.prank(stray);
        erc20.approve(address(spokePool), type(uint256).max);

        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();

        vm.prank(stray);
        vm.expectRevert(V5SpokePoolInterface.V5NotCurrentExecutor.selector);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }

    function testRevertsWhenDepositsArePaused() public {
        vm.prank(owner);
        spokePool.pauseDeposits(true);

        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();

        vm.prank(executor);
        vm.expectRevert(SpokePoolInterface.DepositsArePaused.selector);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }

    function testDepositWithNativeValueWrapsIntoWeth() public {
        // Unlike fills, the deposit action accepts msg.value: a wrapped-native input token plus matching value
        // is wrapped by the deposit pipeline instead of pulled via ERC20.
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.inputToken = address(weth).toBytes32();
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();

        vm.deal(executor, AMOUNT);
        vm.prank(executor);
        spokePool.adapterExecuteAcrossV5{ value: AMOUNT }(_depositPayload(input), abi.encode(jit));

        assertEq(weth.balanceOf(address(spokePool)), AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                        JIT parameter modification
    //////////////////////////////////////////////////////////////*/

    function testJitValuesIgnoredWhenNoFlagsSet() public {
        // With no modification flags, the JIT values are ignored entirely (static deposit).
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT * 2;

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            input.inputToken,
            input.outputToken,
            input.inputAmount,
            input.outputAmount, // unmodified
            input.destinationChainId,
            _expectedDepositId(),
            input.quoteTimestamp,
            input.fillDeadline,
            0,
            input.depositor,
            input.recipient,
            input.exclusiveRelayer,
            _v5DepositMessage()
        );
        _adapterDeposit(input, jit);
    }

    function testAppliesOutputAmountImprovementWithoutAuthority() public {
        // Flag set, no authority: the submitter may improve the output amount freely.
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.paramModificationRules = _rules(FLAG_AMOUNT_OUT, address(0));
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT + 1e18;

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            input.inputToken,
            input.outputToken,
            input.inputAmount,
            jit.newOutputAmount, // improved
            input.destinationChainId,
            _expectedDepositId(),
            input.quoteTimestamp,
            input.fillDeadline,
            0,
            input.depositor,
            input.recipient,
            input.exclusiveRelayer,
            _v5DepositMessage()
        );
        _adapterDeposit(input, jit);
    }

    function testRevertsWhenOutputAmountModificationNotAnImprovement() public {
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.paramModificationRules = _rules(FLAG_AMOUNT_OUT, address(0));
        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT - 1;

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.ParamModificationNotAnImprovement.selector);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }

    function testAppliesAuthoritySignedModificationSet() public {
        // All three parameters dynamic, gated by an authority signature (e.g. an offchain auction outcome).
        address exclusiveRelayer = makeAddr("wonAuction");
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.paramModificationRules = _rules(FLAG_AMOUNT_OUT | FLAG_EXCLUSIVE_RELAYER | FLAG_EXCLUSIVITY, authority);

        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT + 1e18;
        jit.newExclusiveRelayer = exclusiveRelayer.toBytes32();
        jit.newExclusivityParameter = 500; // offset: emitted deadline = now + 500
        jit.signature = _signModifications(jit, authorityKey);

        vm.expectEmit(true, true, true, true);
        emit FundsDeposited(
            input.inputToken,
            input.outputToken,
            input.inputAmount,
            jit.newOutputAmount,
            input.destinationChainId,
            _expectedDepositId(),
            input.quoteTimestamp,
            input.fillDeadline,
            uint32(spokePool.getCurrentTime()) + 500,
            input.depositor,
            input.recipient,
            jit.newExclusiveRelayer,
            _v5DepositMessage()
        );
        _adapterDeposit(input, jit);
    }

    function testRevertsWhenAuthoritySignatureInvalid() public {
        (, uint256 wrongKey) = makeAddrAndKey("notTheAuthority");

        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.paramModificationRules = _rules(FLAG_AMOUNT_OUT, authority);

        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT + 1e18;
        jit.signature = _signModifications(jit, wrongKey);

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.InvalidParamModificationSignature.selector);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }

    function testRevertsWhenAuthoritySignatureCoversDifferentValues() public {
        // A valid authority signature over one modification set cannot be replayed for different values.
        V5SpokePoolInterface.V5DepositInput memory input = _defaultInput();
        input.paramModificationRules = _rules(FLAG_AMOUNT_OUT, authority);

        V5SpokePoolInterface.V5DepositJit memory jit = _defaultJit();
        jit.newOutputAmount = AMOUNT + 1e18;
        jit.signature = _signModifications(jit, authorityKey);
        jit.newOutputAmount = AMOUNT + 2e18; // tamper after signing

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.InvalidParamModificationSignature.selector);
        spokePool.adapterExecuteAcrossV5(_depositPayload(input), abi.encode(jit));
    }
}
