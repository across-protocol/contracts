// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

// ── Minimal external interfaces ──────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address, address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

/// @dev Executors are untrusted external contracts that perform order-specific logic (swaps, bridges, etc.)
interface IExecutor {
    function execute(address orderOwner, bytes calldata stepMessage, bytes calldata executorMessage) external payable;
}

// ── Commands ─────────────────────────────────────────────────────────────────
// Inspired by Uniswap's UniversalRouter: one byte per command, high bit = allow revert.
// Funding (PULL_*) and execution (EXECUTE) commands are freely interleaved,
// so the gateway only pulls the funds each step actually needs.

library Commands {
    bytes1 constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 constant COMMAND_TYPE_MASK = 0x7f;

    // ── Funding: pull tokens into the gateway (0x00–0x0f) ──
    uint8 constant PULL_ERC20 = 0x00; // transferFrom (requires prior approval)
    uint8 constant PULL_PERMIT2 = 0x01; // Permit2 signature-based pull
    uint8 constant PULL_PERMIT2_WITNESS = 0x02; // Permit2 with witness (for orderOwner gasless auth tied to orderId)
    uint8 constant CLAIM_NATIVE = 0x03; // Earmark a portion of msg.value for a subsequent step

    // ── Execution: call external executors (0x10–0x1f) ──
    uint8 constant EXECUTE = 0x10;

    // ── Token management: move tokens out of gateway (0x20–0x2f) ──
    uint8 constant TRANSFER = 0x20; // Send exact amount to recipient
    uint8 constant SWEEP = 0x21; // Send full balance of token to recipient (with min-amount check)

    // ── Assertions (0x30–0x3f) ──
    uint8 constant BALANCE_CHECK = 0x30; // Non-reverting: returns ok=false if balance < threshold
}

// ── OrderGateway ─────────────────────────────────────────────────────────────
// The gateway processes a command sequence that interleaves funding pulls with
// executor calls. This lets multi-step orders pull funds incrementally:
//
//   commands: [PULL_PERMIT2_WITNESS, TRANSFER, EXECUTE,   PULL_ERC20, TRANSFER, EXECUTE,   SWEEP       ]
//   inputs:   [pull_100_usdc,        to_exec1, call_step1, pull_50_dai, to_exec2, call_step2, sweep_to_owner]
//
// Each PULL_* command IS a funding item. The "funding list" is the ordered
// subset of PULL commands in the sequence — no separate Funding struct needed.

contract OrderGateway {
    // ── Errors ──

    error LengthMismatch();
    error InvalidCommand(uint8 command);
    error CommandFailed(uint256 index, bytes reason);
    error NativeOverspend();
    error BalanceTooLow();

    // ── State ──

    IPermit2 public immutable PERMIT2;
    uint8 private _locked = 1;
    uint256 private _nativeUsed; // tracks cumulative msg.value claimed by CLAIM_NATIVE commands

    modifier nonReentrant() {
        require(_locked == 1);
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit2_) {
        PERMIT2 = IPermit2(permit2_);
    }

    // ── Entry point ─────────────────────────────────────────────────────────

    /// @notice Execute an order by processing a command sequence.
    /// @param orderOwner Whose funds PULL commands with source=0 draw from.
    ///                   In practice this comes from a verified Order struct; kept as a raw address
    ///                   here to focus on the funding/execution flow only.
    /// @param commands   Packed command bytes (one byte each, high bit = allow revert).
    /// @param inputs     ABI-encoded inputs for each command.
    function submit(
        address orderOwner,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable nonReentrant {
        uint256 n = commands.length;
        if (inputs.length != n) revert LengthMismatch();

        for (uint256 i; i < n; ++i) {
            bytes1 cmd = commands[i];
            (bool ok, bytes memory out) = _dispatch(uint8(cmd & Commands.COMMAND_TYPE_MASK), inputs[i], orderOwner);
            if (!ok && cmd & Commands.FLAG_ALLOW_REVERT == 0) revert CommandFailed(i, out);
        }

        _nativeUsed = 0;
    }

    // ── Dispatch ────────────────────────────────────────────────────────────
    // Binary-tree branching on command ranges, same pattern as UniversalRouter's Dispatcher.

    function _dispatch(
        uint8 op,
        bytes calldata input,
        address orderOwner
    ) internal returns (bool ok, bytes memory out) {
        ok = true;

        if (op < 0x10) {
            // ── Funding commands ──
            if (op == Commands.PULL_ERC20) {
                // input: (uint8 source, address token, uint256 amount)
                //   source: 0 = orderOwner (requires prior ERC-20 approval), 1 = submitter
                (uint8 src, address token, uint256 amt) = abi.decode(input, (uint8, address, uint256));
                IERC20(token).transferFrom(_source(src, orderOwner), address(this), amt);
            } else if (op == Commands.PULL_PERMIT2) {
                // input: (uint8 source, address token, uint256 amount, uint256 nonce, uint256 deadline, bytes signature)
                (uint8 src, address token, uint256 amt, uint256 nonce, uint256 deadline, bytes memory sig) = abi.decode(
                    input,
                    (uint8, address, uint256, uint256, uint256, bytes)
                );
                PERMIT2.permitTransferFrom(
                    IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
                    IPermit2.SignatureTransferDetails(address(this), amt),
                    _source(src, orderOwner),
                    sig
                );
            } else if (op == Commands.PULL_PERMIT2_WITNESS) {
                // input: (uint8 source, address token, uint256 amount, uint256 nonce, uint256 deadline,
                //         bytes32 witness, string witnessTypeString, bytes signature)
                // The witness ties this permit to a specific orderId, preventing replay across orders.
                (
                    uint8 src,
                    address token,
                    uint256 amt,
                    uint256 nonce,
                    uint256 deadline,
                    bytes32 witness,
                    string memory witnessType,
                    bytes memory sig
                ) = abi.decode(input, (uint8, address, uint256, uint256, uint256, bytes32, string, bytes));
                PERMIT2.permitWitnessTransferFrom(
                    IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
                    IPermit2.SignatureTransferDetails(address(this), amt),
                    _source(src, orderOwner),
                    witness,
                    witnessType,
                    sig
                );
            } else if (op == Commands.CLAIM_NATIVE) {
                // input: (uint256 amount)
                // Earmarks a portion of msg.value. Subsequent TRANSFER/EXECUTE can use the ETH.
                uint256 amt = abi.decode(input, (uint256));
                _nativeUsed += amt;
                if (_nativeUsed > msg.value) revert NativeOverspend();
            } else {
                revert InvalidCommand(op);
            }
        } else if (op < 0x20) {
            // ── Execution commands ──
            // Returns (success, output) so FLAG_ALLOW_REVERT can suppress failures.
            if (op == Commands.EXECUTE) {
                // input: (address executor, bytes stepMessage, bytes executorMessage, uint256 value)
                (address executor, bytes memory stepMsg, bytes memory execMsg, uint256 value) = abi.decode(
                    input,
                    (address, bytes, bytes, uint256)
                );
                (ok, out) = executor.call{ value: value }(
                    abi.encodeCall(IExecutor.execute, (orderOwner, stepMsg, execMsg))
                );
            } else {
                revert InvalidCommand(op);
            }
        } else if (op < 0x30) {
            // ── Token management ──
            if (op == Commands.TRANSFER) {
                // input: (address token, address recipient, uint256 amount)
                // token = address(0) for native ETH
                (address token, address to, uint256 amt) = abi.decode(input, (address, address, uint256));
                _pay(token, to, amt);
            } else if (op == Commands.SWEEP) {
                // input: (address token, address recipient, uint256 minAmount)
                // Sends full gateway balance of `token` to `recipient`.
                (address token, address to, uint256 minAmt) = abi.decode(input, (address, address, uint256));
                uint256 bal = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
                require(bal >= minAmt);
                if (bal > 0) _pay(token, to, bal);
            } else {
                revert InvalidCommand(op);
            }
        } else {
            // ── Assertions ──
            if (op == Commands.BALANCE_CHECK) {
                // input: (address token, address account, uint256 minBalance)
                // Non-reverting: sets ok=false if balance is below threshold.
                (address token, address account, uint256 minBal) = abi.decode(input, (address, address, uint256));
                uint256 bal = token == address(0) ? account.balance : IERC20(token).balanceOf(account);
                ok = bal >= minBal;
                if (!ok) out = abi.encodePacked(BalanceTooLow.selector);
            } else {
                revert InvalidCommand(op);
            }
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _source(uint8 src, address orderOwner) internal view returns (address) {
        return src == 0 ? orderOwner : msg.sender;
    }

    function _pay(address token, address to, uint256 amt) internal {
        if (token == address(0)) {
            (bool sent, ) = to.call{ value: amt }("");
            require(sent);
        } else {
            IERC20(token).transfer(to, amt);
        }
    }

    receive() external payable {}
}
