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

    // ----- Branch 1: action fails -> initialToken returned, finalToken rewritten to initialToken -----
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

    // ----- Branch 2: same input/output token, action consumes more than it returns -----
    // Pre-fix this case incorrectly reported finalAmount = 0.
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
        assertEq(out.amountInEVM, 400e6, "finalAmount = amountInEVM - (X - Y) = 500 - 100 = 400");
        // Harness: 1000 - 500 transfer + 400 drain back = 900.
        assertEq(tokenIn.balanceOf(address(harness)), 900e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
    }

    // ----- Branch 1 (no-op): same token, empty calls -> full amountInEVM returned -----
    function testSameToken_NoCalls() public {
        tokenIn.mint(address(harness), 1000e6);

        ArbitraryEVMFlowExecutor.CompressedCall[] memory calls = new ArbitraryEVMFlowExecutor.CompressedCall[](0);

        EVMFlowParams memory p = _params(address(tokenIn), address(tokenIn), 500e6, abi.encode(calls));
        CommonFlowParams memory out = harness.executeFlow(p);

        assertEq(out.finalToken, address(tokenIn));
        assertEq(out.amountInEVM, 500e6);
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6, "harness balance unchanged");
    }

    // ----- Edge case: same token, profitable (Y > X) ----
    // The `<=` in branch 1 swallows the surplus; documents current behaviour.
    function testSameToken_Profitable_SurplusStaysInContract() public {
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
        // Branch 1 triggers (initialBalance > initialAmountSnapshot via `<=`); reports the original input.
        assertEq(out.amountInEVM, 500e6, "branch 1 reports amountInEVM, ignoring surplus");
        // Harness physically holds 1000 - 500 + 600 = 1100. Surplus of 100 is held but unreported.
        assertEq(tokenIn.balanceOf(address(harness)), 1100e6, "surplus is retained in the contract");
    }

    // ----- Branch 3: different tokens, normal swap -----
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

    // ----- Pre-existing handler dust in initialToken must not orphan the swap output -----
    // Pre-fix: initialBalance from dust drain triggered the "swap didn't happen" branch,
    // rewriting finalToken to initialToken and stranding the actual finalToken output in the executor.
    function testDifferentTokens_HandlerDustInInitialToken_DoesNotOrphanSwapOutput() public {
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

        assertEq(out.finalToken, address(tokenOut), "finalToken must remain tokenOut despite handler dust");
        assertEq(out.amountInEVM, 400e6, "credits actual swap output, not stale initialAmountSnapshot");
        // Harness physically holds 1000 - 500 transferred + 500 dust returned = 1000 tokenIn,
        // plus the 400 tokenOut from the swap. The dust stays on the executor but is not credited to the user.
        assertEq(tokenIn.balanceOf(address(harness)), 1000e6, "handler dust drained back to executor");
        assertEq(tokenOut.balanceOf(address(harness)), 400e6, "swap output preserved");
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0, "handler fully drained");
        assertEq(tokenOut.balanceOf(address(multicallHandler)), 0);
    }

    // ----- Branch 3 (partial consumption): different tokens, leftover initialToken returned -----
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
        assertEq(out.amountInEVM, 400e6, "credits finalToken received");
        // The 200 of unspent initialToken at handler is drained by MulticallHandler's tail drain.
        assertEq(tokenIn.balanceOf(address(harness)), 700e6, "1000 - 500 transferred + 200 leftover returned");
        assertEq(tokenOut.balanceOf(address(harness)), 400e6);
        assertEq(tokenIn.balanceOf(address(multicallHandler)), 0);
    }
}
