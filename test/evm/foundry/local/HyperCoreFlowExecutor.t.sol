// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { BaseSimulatorTest } from "./external/hyper-evm-lib/test/BaseSimulatorTest.sol";
import { PrecompileLib } from "./external/hyper-evm-lib/src/PrecompileLib.sol";
import { HyperCoreLib } from "../../../../contracts/libraries/HyperCoreLib.sol";

import { DonationBox } from "../../../../contracts/chain-adapters/DonationBox.sol";
import { MockERC20 } from "../../../../contracts/test/MockERC20.sol";
import { IHyperCoreFlowExecutor } from "../../../../contracts/test/interfaces/IHyperCoreFlowExecutor.sol";
import { CommonFlowParams } from "../../../../contracts/periphery/mintburn/Structs.sol";
import { HyperCoreFlowExecutor } from "../../../../contracts/periphery/mintburn/HyperCoreFlowExecutor.sol";
import { BaseModuleHandler } from "../../../../contracts/periphery/mintburn/BaseModuleHandler.sol";

contract TestHyperCoreHandler is BaseModuleHandler {
    constructor(address donationBox, address baseToken) BaseModuleHandler(donationBox, baseToken, DEFAULT_ADMIN_ROLE) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PERMISSIONED_BOT_ROLE, msg.sender);
        _grantRole(FUNDS_SWEEPER_ROLE, msg.sender);
    }

    function callExecuteSimpleTransferFlow(CommonFlowParams memory params) external authorizeFundedFlow {
        _delegateToHyperCore(abi.encodeWithSelector(HyperCoreFlowExecutor.executeSimpleTransferFlow.selector, params));
    }

    function callFallbackHyperEVMFlow(CommonFlowParams memory params) external authorizeFundedFlow {
        _delegateToHyperCore(abi.encodeWithSelector(HyperCoreFlowExecutor.fallbackHyperEVMFlow.selector, params));
    }

    function callSetCoreTokenInfo(
        address token,
        uint32 coreIndex,
        bool canBeUsedForAccountActivation,
        uint64 accountActivationFeeCore,
        uint64 bridgeSafetyBufferCore
    ) external {
        _delegateToHyperCore(
            abi.encodeWithSelector(
                HyperCoreFlowExecutor.setCoreTokenInfo.selector,
                token,
                coreIndex,
                canBeUsedForAccountActivation,
                accountActivationFeeCore,
                bridgeSafetyBufferCore
            )
        );
    }
}

contract HyperCoreFlowExecutorTest is BaseSimulatorTest {
    using PrecompileLib for address;

    TestHyperCoreHandler internal handler;
    DonationBox internal donationBox;
    MockERC20 internal token;

    address internal finalRecipient;
    bytes32 internal constant QUOTE_NONCE = keccak256("quote-1");
    uint32 internal constant CORE_INDEX = 0; // USDC index per BaseSimulatorTest

    function setUp() public override {
        super.setUp();

        finalRecipient = makeAddr("finalRecipient");

        token = MockERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f);
        donationBox = new DonationBox();
        handler = new TestHyperCoreHandler(address(donationBox), address(token));

        // Make the handler the owner of DonationBox so it can withdraw during sponsorship
        vm.prank(donationBox.owner());
        donationBox.transferOwnership(address(handler));

        // Set token info in the module via delegatecall
        handler.callSetCoreTokenInfo(address(token), CORE_INDEX, true, 1e6, 1e6);

        // Ensure recipient has an active HyperCore account for sponsored simple transfer path
        hyperCore.forceAccountActivation(finalRecipient);
    }

    function _defaultParams(
        uint256 amountInEVM,
        uint256 maxBpsToSponsor,
        uint256 extraFeesIncurred
    ) internal view returns (CommonFlowParams memory) {
        return
            CommonFlowParams({
                amountInEVM: amountInEVM,
                quoteNonce: QUOTE_NONCE,
                finalRecipient: finalRecipient,
                finalToken: address(token),
                maxBpsToSponsor: maxBpsToSponsor,
                extraFeesIncurred: extraFeesIncurred
            });
    }

    function testExecuteSimpleTransferFlow_Sponsored_EmitsAndUsesDonation() public {
        uint256 amountIn = 1_000e6;
        uint256 extraFees = 50e6; // 5% of amount
        uint256 maxBps = 500; // 5%

        // Ensure bridge has enough liquidity so safety check passes
        address bridgeAddr = HyperCoreLib.toAssetBridgeAddress(CORE_INDEX);
        hyperCore.forceSpot(bridgeAddr, CORE_INDEX, uint64(10_000_000e8)); // large buffer

        // Handler must hold user funds that arrived via bridge
        deal(address(token), address(handler), amountIn, true);
        // Donation box must hold enough to sponsor the extra fees
        deal(address(token), address(donationBox), extraFees, true);

        CommonFlowParams memory params = _defaultParams(amountIn, maxBps, extraFees);

        // Expect the SimpleTransferFlowCompleted event with sponsorship equal to extraFees (capped by bps)
        vm.expectEmit(address(handler));
        emit HyperCoreFlowExecutor.SimpleTransferFlowCompleted(
            // delegated event emitted by handler context
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            params.extraFeesIncurred,
            extraFees
        );
        handler.callExecuteSimpleTransferFlow(params);
    }

    function testExecuteSimpleTransferFlow_Unsponsored_NotActivated_FallsBackToEVM() public {
        // Make recipient not activated
        address unactivated = makeAddr("unactivated");

        uint256 amountIn = 2_000e6;
        uint256 extraFees = 25e6; // ignored as maxBpsToSponsor=0
        uint256 maxBps = 0;

        // Handler holds bridged funds to forward on EVM fallback
        deal(address(token), address(handler), amountIn, true);

        CommonFlowParams memory params = CommonFlowParams({
            amountInEVM: amountIn,
            quoteNonce: keccak256("quote-2"),
            finalRecipient: unactivated,
            finalToken: address(token),
            maxBpsToSponsor: maxBps,
            extraFeesIncurred: extraFees
        });

        uint256 balBefore = IERC20(address(token)).balanceOf(unactivated);

        // Expect FallbackHyperEVMFlowCompleted with zero sponsorship
        vm.expectEmit(address(handler));
        emit HyperCoreFlowExecutor.FallbackHyperEVMFlowCompleted(
            params.quoteNonce,
            params.finalRecipient,
            params.finalToken,
            params.amountInEVM,
            params.extraFeesIncurred,
            0
        );
        handler.callFallbackHyperEVMFlow(params);

        // Recipient received amountIn on EVM
        uint256 balAfter = IERC20(address(token)).balanceOf(unactivated);
        assertEq(balAfter - balBefore, amountIn, "fallback EVM transfer incorrect");
    }
}
