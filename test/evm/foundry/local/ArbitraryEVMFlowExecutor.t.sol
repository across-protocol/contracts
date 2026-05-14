// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import { ArbitraryEVMFlowExecutor } from "../../../../contracts/periphery/mintburn/ArbitraryEVMFlowExecutor.sol";
import {
    CommonFlowParams,
    EVMFlowParams,
    AccountCreationMode
} from "../../../../contracts/periphery/mintburn/Structs.sol";
import { MulticallHandler } from "../../../../contracts/handlers/MulticallHandler.sol";
import { MintableERC20 } from "../../../../contracts/test/MockERC20.sol";

/// @notice Concrete subclass that exposes the internal `_executeFlow` for testing.
contract ExecutorHarness is ArbitraryEVMFlowExecutor {
    constructor(address _multicallHandler) ArbitraryEVMFlowExecutor(_multicallHandler) {}

    function executeFlow(EVMFlowParams memory params) external returns (CommonFlowParams memory) {
        return _executeFlow(params);
    }
}

/// @notice Pulls `amountIn` of `tokenIn` from caller; sends `amountOut` of `tokenOut` to recipient.
/// @dev Pre-fund this contract with the output token. Caller must approve beforehand.
contract MockSwap {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        if (amountIn > 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (amountOut > 0) IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

contract Reverter {
    function fail() external pure {
        revert("nope");
    }
}

contract ArbitraryEVMFlowExecutorTest is Test {
    ExecutorHarness internal harness;
    MulticallHandler internal multicallHandler;
    MockSwap internal swap;
    Reverter internal reverter;

    MintableERC20 internal tokenIn;
    MintableERC20 internal tokenOut;

    address internal finalRecipient = makeAddr("finalRecipient");
    bytes32 internal constant QUOTE_NONCE = keccak256("quote-1");

    function setUp() public {
        multicallHandler = new MulticallHandler();
        harness = new ExecutorHarness(address(multicallHandler));
        swap = new MockSwap();
        reverter = new Reverter();

        tokenIn = new MintableERC20("tokenIn", "TIN", 6);
        tokenOut = new MintableERC20("tokenOut", "TOUT", 6);
    }

    function _buildSwapCalls(
        address tIn,
        address tOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal view returns (ArbitraryEVMFlowExecutor.CompressedCall[] memory calls) {
        calls = new ArbitraryEVMFlowExecutor.CompressedCall[](2);
        calls[0] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: tIn,
            callData: abi.encodeWithSelector(IERC20.approve.selector, address(swap), amountIn)
        });
        calls[1] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: address(swap),
            callData: abi.encodeWithSelector(
                MockSwap.swap.selector,
                tIn,
                tOut,
                amountIn,
                amountOut,
                address(multicallHandler)
            )
        });
    }

    function _params(
        address initialToken,
        address finalToken,
        uint256 amountInEVM,
        bytes memory actionData
    ) internal view returns (EVMFlowParams memory) {
        return
            EVMFlowParams({
                commonParams: CommonFlowParams({
                    amountInEVM: amountInEVM,
                    quoteNonce: QUOTE_NONCE,
                    finalRecipient: finalRecipient,
                    finalToken: finalToken,
                    destinationDex: 0,
                    accountCreationMode: AccountCreationMode.Standard,
                    maxBpsToSponsor: 0,
                    extraFeesIncurred: 0
                }),
                initialToken: initialToken,
                actionData: actionData,
                transferToCore: false
            });
    }

    // ----- Action fails -> initialToken returned, finalToken rewritten to initialToken -----
    function testActionFails_FallsBackToInitialToken() public {
        tokenIn.mint(address(harness), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = new ArbitraryEVMFlowExecutor.CompressedCall[](1);
        calls[0] = ArbitraryEVMFlowExecutor.CompressedCall({
            target: address(reverter),
            callData: abi.encodeWithSelector(Reverter.fail.selector)
        });

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenOut), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenIn), "finalToken should fall back to initialToken");
        assertEq(out.amountInEVM, 500e6, "amountInEVM should equal original input");
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6, "all initialToken returned to harness");
        assertEq(tokenOut.balanceOf(address(harness)), 0, "no finalToken received");
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0, "handler drained");
    }

    // ----- Same input/output token, action consumes more than it returns (net loss) -----
    function testSameToken_PartialConsumption() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenIn.mint(address(swap), 1000e6); // pre-fund swap with output liquidity

        // Consume 300, return 200 of the same token. Net loss = 100.
        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenIn),
            300e6,
            200e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenIn), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenIn), "finalToken unchanged");
        // finalAmount = amountInEVM + eBI - sBI = 500 + 900 - 1000 = 400.
        assertEq(out.amountInEVM, 400e6, "credits net delta against amountInEVM");
        // Harness: 1000 - 500 transfer + 400 drain back = 900.
        assertEq(tokenIn.balanceOf(address(harness)), 900e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
    }

    // ----- Same token, empty calls -> full amountInEVM returned -----
    function testSameToken_NoCalls() public {
        tokenIn.mint(address(harness), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = new ArbitraryEVMFlowExecutor.CompressedCall[](0);

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenIn), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenIn));
        assertEq(out.amountInEVM, 500e6);
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6, "harness balance unchanged");
    }

    // ----- Same token, profitable (Y > X) -> surplus is credited to finalAmount -----
    function testSameToken_Profitable_SurplusIsCredited() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenIn.mint(address(swap), 1000e6);

        // Consume 200, return 300 of the same token (net gain = 100).
        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenIn),
            200e6,
            300e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenIn), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenIn));
        // finalAmount = amountInEVM + eBI - sBI = 500 + 1100 - 1000 = 600.
        assertEq(out.amountInEVM, 600e6, "surplus is credited via balance delta");
        assertEq(tokenIn.balanceOf(address(harness)), 1100e6, "harness physically holds the surplus");
    }

    // ----- Different tokens, normal swap -----
    function testDifferentTokens_NormalSwap() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenOut.mint(address(swap), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenOut),
            500e6,
            400e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenOut), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenOut), "finalToken preserved");
        assertEq(out.amountInEVM, 400e6, "finalAmount = finalToken balance delta");
        assertEq(tokenIn.balanceOf(address(harness)), 500e6, "tokenIn spent fully");
        assertEq(tokenOut.balanceOf(address(harness)), 400e6, "tokenOut received");
    }

    // ----- Pre-existing handler dust in initialToken is drained upfront and not credited to the flow -----
    function testDifferentTokens_HandlerDustInInitialToken_IsDrainedUpfront() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenIn.mint(address(multicallHandler), 500e6); // pre-existing dust on handler
        tokenOut.mint(address(swap), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenOut),
            500e6,
            400e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenOut), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenOut));
        assertEq(out.amountInEVM, 400e6, "credits finalToken balance delta only");
        // _drainMulticallHandlerDust pulled 500 tokenIn back to the harness before the snapshot,
        // so sBI captured it and the swap delta is unaffected by the dust.
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6);
        assertEq(tokenOut.balanceOf(address(harness)), 400e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
        assertEq(tokenOut.balanceOf(address(multicallHandler)), 0);
    }

    // ----- Pre-existing handler dust in finalToken is drained upfront and not credited to the flow -----
    function testDifferentTokens_HandlerDustInFinalToken_IsDrainedUpfront() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenOut.mint(address(multicallHandler), 250e6); // pre-existing finalToken dust on handler
        tokenOut.mint(address(swap), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenOut),
            500e6,
            400e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenOut), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenOut));
        // Without the upfront drain, sBF would have started at 250 and the swap's 400 output
        // would still pass eBF > sBF. Verifying 400e6 here also confirms the dust wasn't double-credited.
        assertEq(out.amountInEVM, 400e6, "finalAmount = eBF - sBF, dust excluded by upfront drain");
        // Harness keeps the drained dust (250) + swap output (400) = 650 tokenOut.
        assertEq(tokenOut.balanceOf(address(harness)), 650e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
        assertEq(tokenOut.balanceOf(address(multicallHandler)), 0);
    }

    // ----- Different tokens, partial consumption: leftover initialToken returned by handler's tail drain -----
    function testDifferentTokens_PartialConsumption_LeftoverInitialTokenReturned() public {
        tokenIn.mint(address(harness), 1000e6);
        tokenOut.mint(address(swap), 1000e6);

        // amountInEVM = 500, but swap only consumes 300 of initialToken (returns 400 of finalToken).
        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = _buildSwapCalls(
            address(tokenIn),
            address(tokenOut),
            300e6,
            400e6
        );

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenOut), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenOut));
        assertEq(out.amountInEVM, 400e6, "finalAmount = eBF - sBF (finalToken delta)");
        // The 200 of unspent initialToken left at handler is returned by handleV3AcrossMessage's tail drain.
        assertEq(tokenIn.balanceOf(address(harness)), 700e6);
        assertEq(tokenOut.balanceOf(address(harness)), 400e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
    }
}
