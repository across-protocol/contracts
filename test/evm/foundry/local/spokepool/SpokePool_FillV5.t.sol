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
import { IAcrossV5Executor } from "../../../../../contracts/interfaces/IAcrossV5Executor.sol";

/// @dev Recipient that records the V5 executor callback so tests can assert it fired with the right payloads.
contract MockV5Executor is IAcrossV5Executor {
    event ExecutedAcrossV5(bytes message, bytes executorMessage);

    function executeAcrossV5(bytes calldata message, bytes calldata executorMessage) external payable override {
        emit ExecutedAcrossV5(message, executorMessage);
    }
}

contract SpokePoolFillV5Test is Test {
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
    address public submitter;
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
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");
        relayer = makeAddr("relayer");

        weth = new WETH9();

        erc20 = new ExpandedERC20("USD Coin", "USDC", 18);
        erc20.addMember(1, address(this));
        destErc20 = new ExpandedERC20("L2 USD Coin", "L2 USDC", 18);
        destErc20.addMember(1, address(this));

        // Gateway must be wired in before the implementation is deployed (it's an immutable).
        gateway = new MockGateway();
        gateway.setSubmitter(submitter);
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

        // Submitter funds the fills, so it holds + approves the output tokens.
        destErc20.mint(submitter, AMOUNT_TO_SEED);
        vm.deal(submitter, AMOUNT_TO_SEED);
        vm.startPrank(submitter);
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
                executorInput: ""
            });
    }

    function _defaultJit() internal view returns (V5SpokePoolInterface.V5FillJit memory) {
        uint32 fillDeadline = uint32(spokePool.getCurrentTime()) + 1000;
        return
            V5SpokePoolInterface.V5FillJit({
                depositor: depositor.toBytes32(),
                exclusiveRelayer: submitter.toBytes32(), // submitter is the exclusive relayer by default
                inputToken: address(erc20).toBytes32(),
                inputAmount: AMOUNT,
                outputAmount: AMOUNT,
                originChainId: ORIGIN_CHAIN_ID,
                depositId: FIRST_DEPOSIT_ID,
                fillDeadline: fillDeadline,
                exclusivityDeadline: fillDeadline, // active exclusivity window
                repaymentChainId: REPAYMENT_CHAIN_ID,
                repaymentAddress: relayer.toBytes32(),
                message: _v5Message(), // relay tag the submitter must echo; validated against the gateway step id
                executorJitInput: ""
            });
    }

    /// @dev The message SpokePool stamps onto every V5 relay: the V5 header followed by the gateway step id.
    function _v5Message() internal view returns (bytes memory) {
        return abi.encodePacked(spokePool.V5_MAGIC_PREFIX(), STEP_ID);
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

    function _execute(
        V5SpokePoolInterface.V5FillInput memory input,
        V5SpokePoolInterface.V5FillJit memory jit
    ) internal {
        vm.prank(address(gateway));
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    /*//////////////////////////////////////////////////////////////
                        executeAcrossV5
    //////////////////////////////////////////////////////////////*/

    function testOnlyGatewayCanExecute() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(relayer);
        vm.expectRevert(V5SpokePoolInterface.V5RequiresGateway.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testRevertsWhenFillsArePaused() public {
        vm.prank(owner);
        spokePool.pauseFills(true);

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.prank(address(gateway));
        vm.expectRevert(SpokePoolInterface.FillsArePaused.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testRevertsWhenOutputAmountBelowMin() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.outputAmount = input.minOutputAmount - 1;

        vm.prank(address(gateway));
        vm.expectRevert(V5SpokePoolInterface.V5OutputAmountTooLow.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testRevertsWhenRelayMessageDoesNotMatchStepId() public {
        // The submitter must echo the V5 relay tag (header ++ current step id); anything else is rejected.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.message = abi.encodePacked(spokePool.V5_MAGIC_PREFIX(), keccak256("wrong-step"));

        vm.prank(address(gateway));
        vm.expectRevert(V5SpokePoolInterface.V5InvalidMessage.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testRevertsWhenSubmitterIsNotExclusiveRelayer() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.exclusiveRelayer = relayer.toBytes32(); // someone other than the submitter

        vm.prank(address(gateway));
        vm.expectRevert(V3SpokePoolInterface.NotExclusiveRelayer.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testFillsWhenExclusivityHasExpiredEvenIfSubmitterNotExclusive() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.exclusiveRelayer = relayer.toBytes32();
        jit.exclusivityDeadline = 0; // exclusivity already over

        _execute(input, jit);

        assertEq(destErc20.balanceOf(recipient), AMOUNT);
    }

    function testRevertsWhenFillDeadlinePassed() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.minOutputAmount = 0;
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.fillDeadline = 0;
        jit.exclusivityDeadline = 0;

        vm.prank(address(gateway));
        vm.expectRevert(V3SpokePoolInterface.ExpiredFillDeadline.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testHappyPathPullsFromSubmitterAndSetsFillStatus() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        uint256 submitterBefore = destErc20.balanceOf(submitter);
        uint256 recipientBefore = destErc20.balanceOf(recipient);

        _execute(input, jit);

        assertEq(destErc20.balanceOf(submitter), submitterBefore - AMOUNT);
        assertEq(destErc20.balanceOf(recipient), recipientBefore + AMOUNT);
        assertEq(spokePool.fillStatuses(_relayHash(input, jit)), FILL_STATUS_FILLED);
    }

    function testEmitsFilledRelayEvent() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

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
                updatedMessageHash: messageHash,
                updatedOutputAmount: jit.outputAmount,
                fillType: V3SpokePoolInterface.FillType.FastFill
            })
        );
        _execute(input, jit);
    }

    function testCannotDoubleFill() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        _execute(input, jit);

        vm.prank(address(gateway));
        vm.expectRevert(V3SpokePoolInterface.RelayFilled.selector);
        spokePool.executeAcrossV5(abi.encode(input), abi.encode(jit));
    }

    function testInvokesExecutorCallbackWhenRecipientIsContract() public {
        MockV5Executor executor = new MockV5Executor();

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.recipient = address(executor).toBytes32();
        input.executorInput = hex"abcd";

        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.executorJitInput = hex"1234";

        vm.expectEmit(true, true, true, true, address(executor));
        emit MockV5Executor.ExecutedAcrossV5(input.executorInput, jit.executorJitInput);
        _execute(input, jit);

        // Output tokens were funded to the executor (the recipient) before the callback.
        assertEq(destErc20.balanceOf(address(executor)), AMOUNT);
    }

    function testNoExecutorCallbackWhenRecipientIsEOA() public {
        // A message is supplied but the recipient is an EOA, so no callback is attempted and the fill still settles.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.executorInput = hex"abcd";
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        _execute(input, jit);

        assertEq(destErc20.balanceOf(recipient), AMOUNT);
    }

    function testForwardsMsgValueToExecutorCallback() public {
        MockV5Executor executor = new MockV5Executor();
        uint256 value = 1 ether;

        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.recipient = address(executor).toBytes32();
        input.executorInput = hex"abcd";
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();
        jit.executorJitInput = hex"1234";

        vm.deal(address(gateway), value);
        vm.prank(address(gateway));
        spokePool.executeAcrossV5{ value: value }(abi.encode(input), abi.encode(jit));

        // The native value is forwarded to the executor; output tokens are settled separately.
        assertEq(address(executor).balance, value);
        assertEq(destErc20.balanceOf(address(executor)), AMOUNT);
    }

    function testRevertsWhenMsgValueButNoExecutorCallback() public {
        uint256 value = 1 ether;

        // A message is supplied but the recipient is an EOA, so no callback fires to consume the native value.
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.executorInput = hex"abcd";
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        vm.deal(address(gateway), value);
        vm.prank(address(gateway));
        vm.expectRevert(V5SpokePoolInterface.V5UnusedMsgValue.selector);
        spokePool.executeAcrossV5{ value: value }(abi.encode(input), abi.encode(jit));
    }

    function testUnwrapsNativeTokenToRecipient() public {
        V5SpokePoolInterface.V5FillInput memory input = _defaultInput();
        input.outputToken = address(weth).toBytes32();
        V5SpokePoolInterface.V5FillJit memory jit = _defaultJit();

        uint256 recipientEthBefore = recipient.balance;
        uint256 submitterWethBefore = weth.balanceOf(submitter);

        _execute(input, jit);

        // V5 fills reuse the shared transfer logic, so a wrapped-native output is unwrapped to native token.
        assertEq(recipient.balance, recipientEthBefore + AMOUNT);
        assertEq(weth.balanceOf(submitter), submitterWethBefore - AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    nonV5Fill MODIFIER GUARD
    //////////////////////////////////////////////////////////////*/

    /// @dev A V3RelayData whose message carries the V5 header, so the nonV5Fill modifier rejects it.
    function _v5TaggedRelayData() internal view returns (V3SpokePoolInterface.V3RelayData memory) {
        return
            V3SpokePoolInterface.V3RelayData({
                depositor: depositor.toBytes32(),
                recipient: recipient.toBytes32(),
                exclusiveRelayer: relayer.toBytes32(),
                inputToken: address(erc20).toBytes32(),
                outputToken: address(destErc20).toBytes32(),
                inputAmount: AMOUNT,
                outputAmount: AMOUNT,
                originChainId: ORIGIN_CHAIN_ID,
                depositId: FIRST_DEPOSIT_ID,
                fillDeadline: uint32(spokePool.getCurrentTime()) + 1000,
                exclusivityDeadline: 0,
                message: abi.encodePacked(spokePool.V5_MAGIC_PREFIX())
            });
    }

    function testFillRelayRejectsV5TaggedMessage() public {
        // Build relay data (which makes view calls) before arming expectRevert.
        V3SpokePoolInterface.V3RelayData memory relayData = _v5TaggedRelayData();

        vm.prank(relayer);
        vm.expectRevert(V5SpokePoolInterface.V5MethodNotAllowed.selector);
        spokePool.fillRelay(relayData, REPAYMENT_CHAIN_ID, relayer.toBytes32());
    }

    function testFillRelayWithUpdatedDepositRejectsV5TaggedMessage() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _v5TaggedRelayData();

        // The modifier reverts before the depositor signature is verified, so dummy update args are fine.
        vm.prank(relayer);
        vm.expectRevert(V5SpokePoolInterface.V5MethodNotAllowed.selector);
        spokePool.fillRelayWithUpdatedDeposit(
            relayData,
            REPAYMENT_CHAIN_ID,
            relayer.toBytes32(),
            AMOUNT,
            recipient.toBytes32(),
            "",
            ""
        );
    }

    function testRequestSlowFillRejectsV5TaggedMessage() public {
        V3SpokePoolInterface.V3RelayData memory relayData = _v5TaggedRelayData();

        vm.prank(relayer);
        vm.expectRevert(V5SpokePoolInterface.V5MethodNotAllowed.selector);
        spokePool.requestSlowFill(relayData);
    }

    function testExecuteSlowRelayLeafRejectsV5TaggedMessage() public {
        V3SpokePoolInterface.V3SlowFill memory slowFillLeaf = V3SpokePoolInterface.V3SlowFill({
            relayData: _v5TaggedRelayData(),
            chainId: DESTINATION_CHAIN_ID,
            updatedOutputAmount: AMOUNT
        });

        // The modifier reverts before any merkle verification, so an empty proof is fine.
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(V5SpokePoolInterface.V5MethodNotAllowed.selector);
        spokePool.executeSlowRelayLeaf(slowFillLeaf, 0, proof);
    }
}
