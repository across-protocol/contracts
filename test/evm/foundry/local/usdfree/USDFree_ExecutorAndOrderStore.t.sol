// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { Executor } from "../../../../../contracts/usdfree/Executor.sol";
import { OrderStore } from "../../../../../contracts/usdfree/OrderStore.sol";
import { Continuation, ContinuationType, ForwardingAmounts, GenericStep, GenericStepType, IUserActionExecutor, RefundConfig, StaticRequirementType, StepAndNext, SubmitterRequirement, TokenRequirementType, TypedData, UserDataType, UserRequirements, UserRequirementsAndAction, UserRequirementsAndSend, AmountTokenRequirement } from "../../../../../contracts/usdfree/Interfaces.sol";
import { MintableERC20 } from "../../../../../contracts/test/MockERC20.sol";

contract MockUserActionExecutor is IUserActionExecutor {
    address public lastErc20Token;
    uint256 public lastErc20Amount;
    uint256 public lastNativeAmount;
    bytes32 public lastOrderId;
    bytes public lastActionParams;
    bytes public lastNextContinuation;

    function execute(
        address token,
        uint256 amount,
        bytes32 orderId,
        bytes calldata actionParams,
        bytes calldata nextContinuation
    ) external payable override {
        if (token != address(0) && amount != 0) IERC20(token).transferFrom(msg.sender, address(this), amount);
        lastErc20Token = token;
        lastErc20Amount = amount;
        lastNativeAmount = msg.value;
        lastOrderId = orderId;
        lastActionParams = actionParams;
        lastNextContinuation = nextContinuation;
    }
}

contract USDFreeExecutorOrderStoreTest is Test {
    Executor internal executor;
    OrderStore internal orderStore;
    MintableERC20 internal token;
    MockUserActionExecutor internal userExecutor;

    address internal constant SUBMITTER = address(0xBEEF);

    function setUp() public {
        executor = new Executor();
        orderStore = new OrderStore(address(executor));
        token = new MintableERC20("Token", "TKN", 18);
        userExecutor = new MockUserActionExecutor();

        executor.setAuthorizedCaller(address(this), true);
    }

    function testExecutor_UsesForwardingAmountsForRequirementAndForwarding() public {
        vm.deal(address(executor), 0.2 ether);
        token.mint(address(executor), 120e18);

        UserRequirementsAndAction memory reqAction = _buildReqAction(
            _minReq(address(token), 100e18),
            new TypedData[](0),
            ForwardingAmounts({ erc20Amount: 120e18, nativeAmount: 0.2 ether })
        );
        StepAndNext memory step = _userStep(reqAction);

        executor.execute(SUBMITTER, bytes32("order-1"), address(token), 0, 0, new bytes[](0), step);

        assertEq(userExecutor.lastErc20Token(), address(token));
        assertEq(userExecutor.lastErc20Amount(), 120e18);
        assertEq(userExecutor.lastNativeAmount(), 0.2 ether);
        assertEq(token.balanceOf(address(userExecutor)), 120e18);
    }

    function testExecutor_DirectTransferFinalActionPushesFundsToRecipient() public {
        address recipient = makeAddr("recipient");
        vm.deal(address(executor), 0.25 ether);
        token.mint(address(executor), 50e18);

        UserRequirementsAndSend memory reqSend = UserRequirementsAndSend({
            reqs: UserRequirements({
                tokenReq: _minReq(address(token), 40e18),
                staticReqs: new TypedData[](0),
                forwarding: ForwardingAmounts({ erc20Amount: 50e18, nativeAmount: 0.25 ether })
            }),
            recipient: recipient
        });
        StepAndNext memory step = _userStepSend(reqSend);

        uint256 nativeBefore = recipient.balance;
        executor.execute(SUBMITTER, bytes32("order-direct"), address(token), 0, 0, new bytes[](0), step);

        assertEq(token.balanceOf(recipient), 50e18);
        assertEq(recipient.balance, nativeBefore + 0.25 ether);
    }

    function testExecutor_RevertsWhenForwardingBelowTokenReq() public {
        token.mint(address(executor), 100e18);

        UserRequirementsAndAction memory reqAction = _buildReqAction(
            _minReq(address(token), 100e18),
            new TypedData[](0),
            ForwardingAmounts({ erc20Amount: 99e18, nativeAmount: 0 })
        );
        StepAndNext memory step = _userStep(reqAction);

        vm.expectRevert(Executor.RequirementNotMet.selector);
        executor.execute(SUBMITTER, bytes32("order-2"), address(token), 0, 0, new bytes[](0), step);
    }

    function testExecutor_SubmitterRequirementAllowsAnyoneAfterExclusivityDeadline() public {
        SubmitterRequirement memory submitterReq = SubmitterRequirement({
            submitter: address(0xABCD),
            exclusivityDeadline: block.timestamp + 100
        });
        TypedData[] memory staticReqs = new TypedData[](1);
        staticReqs[0] = TypedData({ typ: uint8(StaticRequirementType.Submitter), data: abi.encode(submitterReq) });

        UserRequirementsAndAction memory reqAction = _buildReqAction(
            _minReq(address(0), 0),
            staticReqs,
            ForwardingAmounts({ erc20Amount: 0, nativeAmount: 0 })
        );
        StepAndNext memory step = _userStep(reqAction);

        vm.expectRevert(Executor.RequirementNotMet.selector);
        executor.execute(address(0x9999), bytes32("order-3"), address(0), 0, 0, new bytes[](0), step);

        vm.warp(block.timestamp + 101);
        executor.execute(address(0x9999), bytes32("order-3"), address(0), 0, 0, new bytes[](0), step);
    }

    function testOrderStore_UserAndAdminRefundsRespectStoredStepConfig() public {
        address user0 = makeAddr("user0");
        address user1 = makeAddr("user1");
        token.mint(user0, 100e18);
        token.mint(user1, 100e18);

        RefundConfig memory cfg0 = RefundConfig({ refundRecipient: makeAddr("user0Refund"), reverseDeadline: 0 });
        RefundConfig memory cfg1 = RefundConfig({ refundRecipient: address(0), reverseDeadline: 0 });

        vm.startPrank(user0);
        token.approve(address(orderStore), 100e18);
        orderStore.handle(address(token), 100e18, bytes32("store-0"), _stepAndNextDataContinuation(cfg0));
        vm.stopPrank();

        vm.startPrank(user1);
        token.approve(address(orderStore), 100e18);
        orderStore.handle(address(token), 100e18, bytes32("store-1"), _stepAndNextDataContinuation(cfg1));
        vm.stopPrank();

        address user0RefundRecipient = cfg0.refundRecipient;
        uint256 user0Before = token.balanceOf(user0RefundRecipient);
        vm.prank(user0);
        orderStore.refundByUser(0);
        assertEq(token.balanceOf(user0RefundRecipient), user0Before + 100e18);

        uint256 adminBefore = token.balanceOf(address(this));
        orderStore.refundByAdmin(1);
        assertEq(token.balanceOf(address(this)), adminBefore + 100e18);
    }

    function testOrderStore_RefundExpiredReverts() public {
        address user0 = makeAddr("user0");
        token.mint(user0, 50e18);

        RefundConfig memory cfg = RefundConfig({ refundRecipient: user0, reverseDeadline: block.timestamp + 10 });

        vm.startPrank(user0);
        token.approve(address(orderStore), 50e18);
        orderStore.handle(address(token), 50e18, bytes32("store-2"), _stepAndNextDataContinuation(cfg));
        vm.stopPrank();

        vm.warp(block.timestamp + 11);
        vm.prank(user0);
        vm.expectRevert(OrderStore.RefundExpired.selector);
        orderStore.refundByUser(0);
    }

    function testOrderStore_RejectsHashOnlyContinuationForStoredOrders() public {
        address user0 = makeAddr("user0");
        token.mint(user0, 10e18);

        Continuation memory continuation = Continuation({
            typ: ContinuationType.StepAndNextHash,
            data: abi.encode(bytes32("hash"))
        });

        vm.startPrank(user0);
        token.approve(address(orderStore), 10e18);
        vm.expectRevert(OrderStore.InvalidContinuation.selector);
        orderStore.handle(address(token), 10e18, bytes32("store-3"), abi.encode(continuation));
        vm.stopPrank();
    }

    function _buildReqAction(
        TypedData memory tokenReq,
        TypedData[] memory staticReqs,
        ForwardingAmounts memory forwarding
    ) internal view returns (UserRequirementsAndAction memory reqAction) {
        reqAction = UserRequirementsAndAction({
            reqs: UserRequirements({ tokenReq: tokenReq, staticReqs: staticReqs, forwarding: forwarding }),
            target: address(userExecutor),
            userAction: abi.encode("action")
        });
    }

    function _minReq(address tokenAddr, uint256 amount) internal pure returns (TypedData memory) {
        return
            TypedData({
                typ: uint8(TokenRequirementType.MinAmount),
                data: abi.encode(AmountTokenRequirement({ token: tokenAddr, amount: amount }))
            });
    }

    function _userStep(UserRequirementsAndAction memory reqAction) internal pure returns (StepAndNext memory) {
        return
            StepAndNext({
                curStep: GenericStep({
                    typ: GenericStepType.User,
                    refundConfig: RefundConfig({ refundRecipient: address(0), reverseDeadline: 0 }),
                    userData: TypedData({
                        typ: uint8(UserDataType.RequirementsAndActionV1),
                        data: abi.encode(reqAction)
                    }),
                    parts: new bytes[](0)
                }),
                nextContinuation: abi.encode(
                    Continuation({ typ: ContinuationType.GenericSteps, data: abi.encode(new GenericStep[](0)) })
                )
            });
    }

    function _userStepSend(UserRequirementsAndSend memory reqSend) internal pure returns (StepAndNext memory) {
        return
            StepAndNext({
                curStep: GenericStep({
                    typ: GenericStepType.User,
                    refundConfig: RefundConfig({ refundRecipient: address(0), reverseDeadline: 0 }),
                    userData: TypedData({ typ: uint8(UserDataType.RequirementsAndSendV1), data: abi.encode(reqSend) }),
                    parts: new bytes[](0)
                }),
                nextContinuation: abi.encode(
                    Continuation({ typ: ContinuationType.GenericSteps, data: abi.encode(new GenericStep[](0)) })
                )
            });
    }

    function _stepAndNextDataContinuation(RefundConfig memory refundConfig) internal pure returns (bytes memory) {
        GenericStep memory step = GenericStep({
            typ: GenericStepType.User,
            refundConfig: refundConfig,
            userData: TypedData({
                typ: uint8(UserDataType.RequirementsAndActionV1),
                data: abi.encode(_noopReqAction())
            }),
            parts: new bytes[](0)
        });
        StepAndNext memory stepAndNext = StepAndNext({
            curStep: step,
            nextContinuation: abi.encode(
                Continuation({ typ: ContinuationType.GenericSteps, data: abi.encode(new GenericStep[](0)) })
            )
        });
        return abi.encode(Continuation({ typ: ContinuationType.StepAndNextData, data: abi.encode(stepAndNext) }));
    }

    function _noopReqAction() internal pure returns (UserRequirementsAndAction memory) {
        return
            UserRequirementsAndAction({
                reqs: UserRequirements({
                    tokenReq: _minReq(address(0), 0),
                    staticReqs: new TypedData[](0),
                    forwarding: ForwardingAmounts({ erc20Amount: 0, nativeAmount: 0 })
                }),
                target: address(0x1),
                userAction: ""
            });
    }
}
