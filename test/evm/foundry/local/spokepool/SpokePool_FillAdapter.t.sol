// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Proxy.sol";
import { MockSpokePool } from "../../../../../contracts/test/MockSpokePool.sol";
import { MockGateway } from "../../../../../contracts/test/MockGateway.sol";
import { WETH9 } from "../../../../../contracts/external/WETH9.sol";
import { ExpandedERC20 } from "../../../../../contracts/external/uma/core/contracts/common/implementation/ExpandedERC20.sol";
import { AddressToBytes32, Bytes32ToAddress } from "../../../../../contracts/libraries/AddressConverters.sol";
import { V3SpokePoolInterface } from "../../../../../contracts/interfaces/V3SpokePoolInterface.sol";
import { V5SpokePoolInterface } from "../../../../../contracts/interfaces/V5SpokePoolInterface.sol";
import { SpokePoolInterface } from "../../../../../contracts/interfaces/SpokePoolInterface.sol";

/// @notice Tests for the Executor-driven V5 fill path: `adapterExecuteAcrossV5`.
/// @dev This mirrors the Gateway-direct `executeAcrossV5` suite but exercises the differences of the adapter
/// path:
/// (1) it is callable ONLY by the live step's committed executor (`gateway.currentExecutor()`), which reads
///     zero while the Gateway is idle AND during its uncommitted funding loop;
/// (2) output tokens are pulled from `msg.sender` (the Executor's own balance) rather than from the Gateway's
///     submitter;
/// (3) there is no trailing call: committing a callback message is rejected, and delivery-then-action belongs
///     in the tape.
/// Shared fill semantics (witness, exclusivity-vs-submitter, min output, dedupe) run through `_fillV5`.
contract SpokePoolFillAdapterTest is Test {
    using AddressToBytes32 for address;
    using Bytes32ToAddress for bytes32;

    MockSpokePool public spokePool;
    MockGateway public gateway;
    WETH9 public weth;
    ExpandedERC20 public erc20; // origin/input token (only used as a label)
    ExpandedERC20 public destErc20; // destination/output token

    address public owner;
    address public crossDomainAdmin;
    address public hubPool;
    address public submitter; // the Gateway's current submitter (exclusivity is checked against this)
    address public executor; // the committed Executor: the only allowed caller, and the fill's funder
    address public depositor;
    address public recipient;
    address public relayer; // repayment address credited in the event

    bytes32 public constant STEP_ID = keccak256("step-1");

    uint256 public constant AMOUNT_TO_SEED = 1500e18;
    uint256 public constant AMOUNT = 100e18;
    uint256 public constant DESTINATION_CHAIN_ID = 1342;
    uint256 public constant ORIGIN_CHAIN_ID = 666;
    uint256 public constant REPAYMENT_CHAIN_ID = 777;
    uint256 public constant FIRST_DEPOSIT_ID = 0;

    uint256 public constant FILL_STATUS_FILLED = 2;

    event FilledRelay(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 repaymentChainId,
        uint256 indexed originChainId,
        uint256 indexed depositId,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 exclusiveRelayer,
        bytes32 indexed relayer,
        bytes32 depositor,
        bytes32 recipient,
        bytes32 messageHash,
        V3SpokePoolInterface.V3RelayExecutionEventInfo relayExecutionInfo
    );

    function setUp() public {
        owner = makeAddr("owner");
        crossDomainAdmin = makeAddr("crossDomainAdmin");
        hubPool = makeAddr("hubPool");
        submitter = makeAddr("submitter");
        executor = makeAddr("executor");
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        weth = new WETH9();

        erc20 = new ExpandedERC20("USD Coin", "USDC", 18);
        erc20.addMember(1, address(this));
        destErc20 = new ExpandedERC20("L2 USD Coin", "L2 USDC", 18);
        destErc20.addMember(1, address(this));

        // Gateway must be wired in before the implementation is deployed (it's an immutable). The executor
        // field mimics the live executor-call window on the real Gateway.
        gateway = new MockGateway();
        gateway.setSubmitter(submitter);
        gateway.setExecutor(executor);
        gateway.setStepId(STEP_ID);

        vm.startPrank(owner);
        MockSpokePool implementation = new MockSpokePool(address(weth), address(gateway));
        address proxy = address(
            new ERC1967Proxy(
                address(implementation),
                abi.encodeCall(MockSpokePool.initialize, (0, crossDomainAdmin, hubPool))
            )
        );
        spokePool = MockSpokePool(payable(proxy));
        spokePool.setChainId(DESTINATION_CHAIN_ID);
        vm.stopPrank();

        // The Executor (the adapter caller), NOT the submitter, funds adapter fills, so it holds + approves the
        // output tokens. The submitter is funded too so that a fill wrongly pulling from the submitter would be
        // caught by the balance assertions below.
        _fund(executor);
        _fund(submitter);
    }

    function _fund(address who) internal {
        destErc20.mint(who, AMOUNT_TO_SEED);
        vm.deal(who, AMOUNT_TO_SEED);
        vm.startPrank(who);
        weth.deposit{ value: AMOUNT_TO_SEED }();
        destErc20.approve(address(spokePool), type(uint256).max);
        weth.approve(address(spokePool), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultInput() internal view returns (V5SpokePoolInterface.V5FillInput memory) {
        return
            V5SpokePoolInterface.V5FillInput({
                recipient: recipient.toBytes32(),
                outputToken: address(destErc20).toBytes32(),
                minOutputAmount: AMOUNT,
                message: "" // adapter fills have no trailing call, so no callback message may be committed
            });
    }

    function _defaultJit() internal view returns (V5SpokePoolInterface.V5FillJit memory) {
        uint32 fillDeadline = uint32(spokePool.getCurrentTime()) + 1000;
        return
            V5SpokePoolInterface.V5FillJit({
                depositor: depositor.toBytes32(),
                inputToken: address(erc20).toBytes32(),
                inputAmount: AMOUNT,
                outputAmount: AMOUNT,
                originChainId: ORIGIN_CHAIN_ID,
                depositId: FIRST_DEPOSIT_ID,
                fillDeadline: fillDeadline,
                exclusivityDeadline: fillDeadline, // active exclusivity window
                exclusiveRelayer: submitter.toBytes32(), // exclusivity is checked against the submitter, not the caller
                repaymentChainId: REPAYMENT_CHAIN_ID,
                repaymentAddress: relayer.toBytes32()
            });
    }

    /// @dev The relay tag SpokePool stamps onto every V5 fill: the V5 magic prefix followed by the live gateway
    /// step id. Constructed by the SpokePool — never supplied by the submitter.
    function _v5Message() internal view returns (bytes memory) {
        return abi.encodePacked(spokePool.V5_MAGIC_PREFIX(), STEP_ID);
    }

    /// @dev Encodes the adapter `input` for a fill: the ABI-encoded `V5FillInput`.
    function _fillPayload(V5SpokePoolInterface.V5FillInput memory input) internal pure returns (bytes memory) {
        return abi.encode(input);
    }

    /// @dev Executes an adapter fill as `caller`, which funds the output tokens.
    function _adapterFillFrom(
        address caller,
        V5SpokePoolInterface.V5FillInput memory input,
        V5SpokePoolInterface.V5FillJit memory jit
    ) internal {
        vm.prank(caller);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function _adapterFill(
        V5SpokePoolInterface.V5FillInput memory input,
        V5SpokePoolInterface.V5FillJit memory jit
    ) internal {
        _adapterFillFrom(executor, input, jit);
    }

    function _relayData(
        V5SpokePoolInterface.V5FillInput memory input,
        V5SpokePoolInterface.V5FillJit memory jit
    ) internal view returns (V3SpokePoolInterface.V3RelayData memory) {
        return
            V3SpokePoolInterface.V3RelayData({
                depositor: jit.depositor,
                recipient: input.recipient,
                exclusiveRelayer: jit.exclusiveRelayer,
                inputToken: jit.inputToken,
                outputToken: input.outputToken,
                inputAmount: jit.inputAmount,
                outputAmount: jit.outputAmount,
                originChainId: jit.originChainId,
                depositId: jit.depositId,
                fillDeadline: jit.fillDeadline,
                exclusivityDeadline: jit.exclusivityDeadline,
                message: _v5Message()
            });
    }

    function _relayHash(
        V5SpokePoolInterface.V5FillInput memory input,
        V5SpokePoolInterface.V5FillJit memory jit
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(_relayData(input, jit), DESTINATION_CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                        adapter fill: funding + access
    //////////////////////////////////////////////////////////////*/

    function testHappyPathPullsFromCallerNotSubmitter() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        uint256 executorBefore = destErc20.balanceOf(executor);
        uint256 submitterBefore = destErc20.balanceOf(submitter);
        uint256 recipientBefore = destErc20.balanceOf(recipient);

        _adapterFill(input, jit);

        // Output tokens come from the caller (Executor), NOT the Gateway submitter.
        assertEq(destErc20.balanceOf(executor), executorBefore - AMOUNT);
        assertEq(destErc20.balanceOf(submitter), submitterBefore);
        assertEq(destErc20.balanceOf(recipient), recipientBefore + AMOUNT);
        assertEq(spokePool.fillStatuses(_relayHash(input, jit)), FILL_STATUS_FILLED);
    }

    function testRevertsWhenCallerIsNotCurrentExecutor() public {
        // Only the live step's committed executor may call the adapter — code that merely gains control
        // mid-execution (a token hook, a protocol callback) is rejected even though an execution is live.
        address stray = makeAddr("strayCaller");
        _fund(stray);

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(stray);
        vm.expectRevert(V5SpokePoolInterface.V5NotCurrentExecutor.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testRevertsDuringFundingLoopState() public {
        // On the real Gateway, `currentExecutor` is zero during the uncommitted funding loop even though the
        // submitter and step id are already live — the executor boundary rejects that state too.
        gateway.setExecutor(address(0));

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.V5NotCurrentExecutor.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testRevertsWhenFillsArePaused() public {
        vm.prank(owner);
        spokePool.pauseFills(true);

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(executor);
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    /*//////////////////////////////////////////////////////////////
                    adapter fill: shared _fillV5 semantics
    //////////////////////////////////////////////////////////////*/

    function testRevertsWhenOutputAmountBelowMin() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.outputAmount = input.minOutputAmount - 1;

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.V5OutputAmountTooLow.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testRevertsWhenSubmitterIsNotExclusiveRelayer() public {
        // Exclusivity is enforced against the Gateway submitter, not the (Executor) caller.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.exclusiveRelayer = relayer.toBytes32(); // someone other than the submitter

        vm.prank(executor);
        vm.expectRevert(V3SpokePoolInterface.NotExclusiveRelayer.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testFillsWhenExclusivityHasExpiredEvenIfSubmitterNotExclusive() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.exclusiveRelayer = relayer.toBytes32();
        jit.exclusivityDeadline = 0; // exclusivity already over

        _adapterFill(input, jit);

        assertEq(destErc20.balanceOf(recipient), AMOUNT);
    }

    function testRevertsWhenFillDeadlinePassed() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.minOutputAmount = 0;
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.fillDeadline = 0;
        jit.exclusivityDeadline = 0;

        vm.prank(executor);
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testCannotDoubleFill() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        _adapterFill(input, jit);

        vm.prank(executor);
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testEmitsFilledRelayEvent() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        // messageHash covers the stamped witness message; updatedMessageHash covers the committed callback
        // message, which is always empty for adapter fills.
        bytes32 messageHash = keccak256(_v5Message());

        vm.expectEmit(true, true, true, true);
        emit FilledRelay(
            jit.inputToken,
            input.outputToken,
            jit.inputAmount,
            jit.outputAmount,
            jit.repaymentChainId,
            jit.originChainId,
            jit.depositId,
            jit.fillDeadline,
            jit.exclusivityDeadline,
            jit.exclusiveRelayer,
            jit.repaymentAddress,
            jit.depositor,
            input.recipient,
            messageHash,
            V3SpokePoolInterface.V3RelayExecutionEventInfo({
                updatedRecipient: input.recipient,
                updatedMessageHash: bytes32(0),
                updatedOutputAmount: jit.outputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        _adapterFill(input, jit);
    }

    /*//////////////////////////////////////////////////////////////
                    adapter fill: no trailing call
    //////////////////////////////////////////////////////////////*/

    function testRevertsWhenCallbackMessageCommitted() public {
        // Adapter fills are delivery-only: delivery-then-action is expressed by tape position, so committing a
        // callback message is rejected rather than silently ignored.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.message = hex"abcd";
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.V5CallbackNotAllowed.selector);
        spokePool.adapterExecuteAcrossV5(_fillPayload(input), abi.encode(jit));
    }

    function testRevertsOnMsgValue() public {
        // Fills never accept native value; the entrypoint is payable only because the adapter interface requires it.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.deal(executor, 1 ether);
        vm.prank(executor);
        vm.expectRevert(V5SpokePoolInterface.V5UnusedMsgValue.selector);
        spokePool.adapterExecuteAcrossV5{ value: 1 ether }(_fillPayload(input), abi.encode(jit));
    }

    function testUnwrapsNativeTokenToRecipient() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.outputToken = address(weth).toBytes32();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        uint256 recipientEthBefore = recipient.balance;
        uint256 executorWethBefore = weth.balanceOf(executor);

        _adapterFill(input, jit);

        // A wrapped-native output is unwrapped to native token for the recipient; the WETH is pulled from the caller.
        assertEq(recipient.balance, recipientEthBefore + AMOUNT);
        assertEq(weth.balanceOf(executor), executorWethBefore - AMOUNT);
    }
}
