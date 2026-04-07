// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Step, Funding, TypedData, SubmitterInputs, USDFreeIdLib } from "./Interfaces.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    // Allowance-based transfer — uses pre-set approval, no per-transfer signature
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

interface IExecutor {
    function execute(address orderOwner, bytes calldata stepMessage, bytes calldata executorMessage) external payable;
}

// ── Commands ─────────────────────────────────────────────────────────────────
// Command byte layout:
//   Bits 6-7: input source
//     00 = owner input only
//     01 = submitter input only
//     10 = both (merged as abi.encode(ownerInput, submitterInput))
//     11 = reserved
//   Bit 5 (0x20): FLAG_ALLOW_REVERT — failure doesn't revert the tx
//   Bits 0-4:     command type (0x00–0x1f)
//
// step.message encodes the owner's plan:
//   abi.encode(bytes commands, bytes[] ownerInputs)
//
// executorMessage encodes the submitter's contributions:
//   abi.encode(bytes[] submitterInputs)
//
// EXECUTE with INPUT_BOTH: owner provides (uint256 value, bytes executorStepMsg),
// submitter provides (bytes executorDynMsg). No special top-level fields needed.

library Commands {
    bytes1 constant INPUT_SOURCE_MASK = 0xC0;
    bytes1 constant INPUT_OWNER = 0x00;
    bytes1 constant INPUT_SUBMITTER = 0x40;
    bytes1 constant INPUT_BOTH = 0x80;

    bytes1 constant FLAG_ALLOW_REVERT = 0x20;
    bytes1 constant COMMAND_TYPE_MASK = 0x1f;

    uint8 constant PULL_ERC20 = 0x00;
    uint8 constant PULL_3009 = 0x01;
    uint8 constant PULL_PERMIT2_WITNESS = 0x02;
    uint8 constant CLAIM_NATIVE = 0x03;
    // Allowance-based Permit2 pull — requires pre-set permit2.approve + prior VERIFY_CONTEXT command.
    // Input: (uint8 source, address token, uint160 amount)
    uint8 constant PULL_PERMIT2_ALLOWANCE = 0x04;
    // Verifies an EIP-712 context signature from orderOwner over orderId.
    // Must run before any PULL_PERMIT2_ALLOWANCE commands. Sets _contextVerified = true.
    // Input: (bytes signature) — 65-byte EIP-712 sig. Always FLAG_SUBMITTER_INPUT (submitter provides the sig).
    uint8 constant VERIFY_CONTEXT = 0x05;

    // Calls step.executor.execute(orderOwner, executorStepMessage, executorDynamicMessage)
    // Input: (uint256 value)
    uint8 constant EXECUTE = 0x10;

    // Delegatecalls into an approved adapter (runs in gateway context).
    // Input: (address adapter, bytes data)
    // With INPUT_BOTH: owner provides (address adapter), submitter provides (bytes data).
    uint8 constant CALL_ADAPTER = 0x11;

    // Injects current token balances into calldata, then calls target.
    // Input: (address target, bytes callData, uint256 value, Replacement[] replacements)
    uint8 constant CALL_WITH_BALANCE = 0x12;

    uint8 constant TRANSFER = 0x14;
    uint8 constant SWEEP = 0x15;

    // Non-reverting balance assertion (use without FLAG_ALLOW_REVERT for hard requirements)
    uint8 constant BALANCE_CHECK = 0x18;
    // Record a balance for later delta comparison. Input: (uint8 slotId, address token, address account)
    uint8 constant SNAPSHOT_BALANCE = 0x19;
    // Check balance change since snapshot. Input: (uint8 slotId, address token, address account, int256 minDelta)
    uint8 constant CHECK_DELTA = 0x1a;
}

// ── Structs ──────────────────────────────────────────────────────────────────

struct Replacement {
    address token; // address(0) for native ETH
    uint256 offset; // byte offset in callData to inject balance
}

// ── OrderGateway ─────────────────────────────────────────────────────────────

contract OrderGateway is Ownable, ReentrancyGuard {
    // ── Errors ──

    error LengthMismatch();
    error InvalidCommand(uint8 command);
    error CommandFailed(uint256 index, bytes reason);
    error NativeOverspend();
    error BalanceTooLow();
    error NonceAlreadyUsed();
    error InvalidStepProof();
    error InvalidWitness();
    error NotActiveExecutor();
    error InvalidFundingType(uint8 typ);
    error AdapterNotApproved(address adapter);
    error CalldataTooShort(uint256 callDataLength, uint256 offset);
    error InvalidContextSignature();

    // ── Events ──

    event OrderSubmitted(
        bytes32 indexed orderId,
        bytes32 indexed executionId,
        bytes32 stepId,
        address indexed orderOwner,
        address submitter
    );

    // ── EIP-712 (for context signatures) ──

    bytes32 private constant _ORDER_CONTEXT_TYPEHASH = keccak256("OrderContext(bytes32 orderId)");

    // ── Immutables ──

    IPermit2 public immutable PERMIT2;
    bytes32 public immutable DOMAIN_HASH; // USDFreeIdLib domain
    bytes32 public immutable EIP712_DOMAIN_SEPARATOR; // EIP-712 domain for context signatures

    // ── State ──

    uint256 private _nativeUsed;
    address private _activeExecutor;
    address private _orderOwner;
    bytes32 private _orderId;
    mapping(bytes32 orderId => bool) public usedNonces;
    mapping(uint8 slotId => uint256) private _snapshots;
    mapping(address adapter => bool) public approvedAdapters;
    bool private _contextVerified; // true when orderOwner's context signature has been verified

    constructor(address permit2_, uint32 chainId, address owner_) Ownable(owner_) {
        PERMIT2 = IPermit2(permit2_);
        DOMAIN_HASH = USDFreeIdLib.domainHash(chainId, address(this));
        EIP712_DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("USDFree.OrderGateway"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setAdapterApproval(address adapter, bool approved) external onlyOwner {
        approvedAdapters[adapter] = approved;
    }

    // ── Entry point ─────────────────────────────────────────────────────────

    function submit(
        Order calldata order,
        Funding calldata orderOwnerFunding,
        SubmitterInputs calldata submitterInputs
    ) external payable nonReentrant {
        _orderId = USDFreeIdLib.orderId(DOMAIN_HASH, order);
        _orderOwner = order.orderOwner;

        if (order.nonce != bytes32(0)) {
            if (usedNonces[_orderId]) revert NonceAlreadyUsed();
            usedNonces[_orderId] = true;
        }

        if (!_verifyProof(submitterInputs.proof, order.root, _stepLeaf(submitterInputs.step)))
            revert InvalidStepProof();

        // ── Process pre-authorized funding ──
        _processFunding(orderOwnerFunding, true);
        _processFunding(submitterInputs.funding, false);

        // ── Decode and execute commands ──
        _executeFromStep(submitterInputs);

        bytes32 stepId_ = USDFreeIdLib.stepId(_orderId, submitterInputs.step);
        emit OrderSubmitted(
            _orderId,
            USDFreeIdLib.executionId(_orderId, stepId_, submitterInputs),
            stepId_,
            order.orderOwner,
            msg.sender
        );

        _nativeUsed = 0;
        _orderId = bytes32(0);
        _orderOwner = address(0);
        _contextVerified = false;
    }

    // ── Command execution ───────────────────────────────────────────────────

    function _executeFromStep(SubmitterInputs calldata si) internal {
        (bytes memory commands, bytes[] memory ownerInputs) = abi.decode(si.step.message, (bytes, bytes[]));
        bytes[] memory subInputs = abi.decode(si.executorMessage, (bytes[]));

        uint256 ownerIdx;
        uint256 subIdx;

        for (uint256 i; i < commands.length; ++i) {
            bytes1 cmd = commands[i];
            uint8 op = uint8(cmd & Commands.COMMAND_TYPE_MASK);

            // Select input source based on bits 6-7
            bytes memory input;
            bytes1 source = cmd & Commands.INPUT_SOURCE_MASK;
            if (source == Commands.INPUT_BOTH) {
                input = abi.encode(ownerInputs[ownerIdx++], subInputs[subIdx++]);
            } else if (source == Commands.INPUT_SUBMITTER) {
                input = subInputs[subIdx++];
            } else {
                input = ownerInputs[ownerIdx++];
            }

            bool ok;
            bytes memory out;

            if (op == Commands.EXECUTE) {
                (ok, out) = _executeStep(si.step, input);
            } else {
                (ok, out) = _dispatch(op, input);
            }

            if (!ok && cmd & Commands.FLAG_ALLOW_REVERT == 0) revert CommandFailed(i, out);
        }
    }

    // ── Executor callbacks ──────────────────────────────────────────────────

    function pullTokens(address token, uint256 amount) external {
        if (msg.sender != _activeExecutor) revert NotActiveExecutor();
        _pay(token, msg.sender, amount);
    }

    function availableBalance(address token) external view returns (uint256) {
        return _balanceOf(token, address(this));
    }

    // ── Context signature verification ─────────────────────────────────────
    // Verifies a one-time EIP-712 signature from the orderOwner over the orderId.
    // Enables cheap allowance-based Permit2 pulls for the rest of the tx.

    function _verifyContextSignature(bytes memory input) internal {
        bytes memory sig = abi.decode(input, (bytes));
        bytes32 structHash = keccak256(abi.encode(_ORDER_CONTEXT_TYPEHASH, _orderId));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", EIP712_DOMAIN_SEPARATOR, structHash));

        if (sig.length != 65) revert InvalidContextSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != _orderOwner) revert InvalidContextSignature();
        _contextVerified = true;
    }

    // ── Step verification ───────────────────────────────────────────────────

    function _stepLeaf(Step calldata step) internal pure returns (bytes32) {
        return keccak256(abi.encode(step.salt, step.executor, keccak256(step.message)));
    }

    function _verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            hash = hash <= p ? keccak256(abi.encodePacked(hash, p)) : keccak256(abi.encodePacked(p, hash));
        }
        return hash == root;
    }

    // ── Funding processing ──────────────────────────────────────────────────

    function _processFunding(Funding calldata funding, bool isOwner) internal {
        address from = isOwner ? _orderOwner : msg.sender;
        for (uint256 i; i < funding.funding.length; ++i) {
            _processFundingItem(funding.funding[i], from);
        }
    }

    function _processFundingItem(TypedData calldata item, address from) internal {
        if (item.typ == 0) {
            (address token, uint256 amt) = abi.decode(item.data, (address, uint256));
            IERC20(token).transferFrom(from, address(this), amt);
        } else if (item.typ == 1) {
            _processFunding3009(item, from);
        } else if (item.typ == 2) {
            _processFundingPermit2(item, from);
        } else if (item.typ == 3) {
            // PERMIT2_ALLOWANCE: uses pre-set allowance + context signature for auth
            require(_contextVerified);
            (address token, uint160 amt) = abi.decode(item.data, (address, uint160));
            PERMIT2.transferFrom(from, address(this), amt, token);
        } else {
            revert InvalidFundingType(item.typ);
        }
    }

    function _processFunding3009(TypedData calldata item, address from) internal {
        (address token, uint256 amt, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s) = abi
            .decode(item.data, (address, uint256, uint256, uint256, uint8, bytes32, bytes32));
        IERC20Auth(token).receiveWithAuthorization(
            from,
            address(this),
            amt,
            validAfter,
            validBefore,
            _orderId,
            v,
            r,
            s
        );
    }

    function _processFundingPermit2(TypedData calldata item, address from) internal {
        (address token, uint256 amt, uint256 nonce, uint256 deadline, string memory witnessType, bytes memory sig) = abi
            .decode(item.data, (address, uint256, uint256, uint256, string, bytes));
        PERMIT2.permitWitnessTransferFrom(
            IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
            IPermit2.SignatureTransferDetails(address(this), amt),
            from,
            _orderId,
            witnessType,
            sig
        );
    }

    // ── Executor dispatch ───────────────────────────────────────────────────

    /// @dev With INPUT_BOTH: input = abi.encode(ownerInput, submitterInput)
    ///      ownerInput = abi.encode(uint256 value, bytes executorStepMsg)
    ///      submitterInput = abi.encode(bytes executorDynMsg)
    ///      With INPUT_OWNER: input = abi.encode(uint256 value, bytes executorStepMsg) (no dynamic msg)
    function _executeStep(Step calldata step, bytes memory input) internal returns (bool ok, bytes memory out) {
        (bytes memory ownerInput, bytes memory subInput) = abi.decode(input, (bytes, bytes));
        (uint256 value, bytes memory executorStepMsg) = abi.decode(ownerInput, (uint256, bytes));
        _activeExecutor = step.executor;
        (ok, out) = step.executor.call{ value: value }(
            abi.encodeCall(IExecutor.execute, (_orderOwner, executorStepMsg, subInput))
        );
        _activeExecutor = address(0);
    }

    // ── Command dispatch ────────────────────────────────────────────────────

    function _dispatch(uint8 op, bytes memory input) internal returns (bool ok, bytes memory out) {
        ok = true;

        if (op < 0x10) {
            _dispatchFunding(op, input);
        } else if (op < 0x14) {
            _dispatchExecution(op, input, ok, out);
        } else if (op < 0x18) {
            _dispatchTokenOps(op, input);
        } else {
            (ok, out) = _dispatchAssertions(op, input);
        }
    }

    function _dispatchFunding(uint8 op, bytes memory input) internal {
        if (op == Commands.PULL_ERC20) {
            (uint8 src, address token, uint256 amt) = abi.decode(input, (uint8, address, uint256));
            IERC20(token).transferFrom(_source(src), address(this), amt);
        } else if (op == Commands.PULL_3009) {
            _pull3009(input);
        } else if (op == Commands.PULL_PERMIT2_WITNESS) {
            _pullPermit2Witness(input);
        } else if (op == Commands.CLAIM_NATIVE) {
            uint256 amt = abi.decode(input, (uint256));
            _nativeUsed += amt;
            if (_nativeUsed > msg.value) revert NativeOverspend();
        } else if (op == Commands.PULL_PERMIT2_ALLOWANCE) {
            require(_contextVerified);
            (uint8 src, address token, uint160 amt) = abi.decode(input, (uint8, address, uint160));
            PERMIT2.transferFrom(_source(src), address(this), amt, token);
        } else if (op == Commands.VERIFY_CONTEXT) {
            _verifyContextSignature(input);
        } else {
            revert InvalidCommand(op);
        }
    }

    function _dispatchExecution(uint8 op, bytes memory input, bool ok, bytes memory out) internal {
        if (op == Commands.CALL_ADAPTER) {
            // Decode adapter address and data. With INPUT_BOTH, input = abi.encode(ownerPart, subPart)
            // where ownerPart = abi.encode(address adapter), subPart = adapter calldata.
            // With INPUT_OWNER, input = abi.encode(address adapter, bytes data) directly.
            (address adapter, bytes memory data) = abi.decode(input, (address, bytes));
            if (!approvedAdapters[adapter]) revert AdapterNotApproved(adapter);
            (ok, out) = adapter.delegatecall(data);
        } else if (op == Commands.CALL_WITH_BALANCE) {
            (ok, out) = _callWithBalance(input);
        } else {
            revert InvalidCommand(op);
        }
    }

    function _dispatchTokenOps(uint8 op, bytes memory input) internal {
        if (op == Commands.TRANSFER) {
            (address token, address to, uint256 amt) = abi.decode(input, (address, address, uint256));
            _pay(token, to, amt);
        } else if (op == Commands.SWEEP) {
            (address token, address to, uint256 minAmt) = abi.decode(input, (address, address, uint256));
            uint256 bal = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
            require(bal >= minAmt);
            if (bal > 0) _pay(token, to, bal);
        } else {
            revert InvalidCommand(op);
        }
    }

    function _dispatchAssertions(uint8 op, bytes memory input) internal returns (bool ok, bytes memory out) {
        ok = true;
        if (op == Commands.BALANCE_CHECK) {
            (address token, address account, uint256 minBal) = abi.decode(input, (address, address, uint256));
            ok = _balanceOf(token, account) >= minBal;
            if (!ok) out = abi.encodePacked(BalanceTooLow.selector);
        } else if (op == Commands.SNAPSHOT_BALANCE) {
            (uint8 slotId, address token, address account) = abi.decode(input, (uint8, address, address));
            _snapshots[slotId] = _balanceOf(token, account);
        } else if (op == Commands.CHECK_DELTA) {
            (uint8 slotId, address token, address account, int256 minDelta) = abi.decode(
                input,
                (uint8, address, address, int256)
            );
            int256 delta = int256(_balanceOf(token, account)) - int256(_snapshots[slotId]);
            ok = delta >= minDelta;
            if (!ok) out = abi.encodePacked(BalanceTooLow.selector);
        } else {
            revert InvalidCommand(op);
        }
    }

    // ── CALL_WITH_BALANCE ────────────────────────────────────────────────────
    // Ported from MulticallHandler.makeCallWithBalance — injects current token
    // balances into calldata at specified offsets before calling the target.

    function _callWithBalance(bytes memory input) internal returns (bool ok, bytes memory out) {
        (address target, bytes memory callData, uint256 value, Replacement[] memory replacements) = abi.decode(
            input,
            (address, bytes, uint256, Replacement[])
        );

        for (uint256 i; i < replacements.length; ++i) {
            uint256 bal;
            if (replacements[i].token != address(0)) {
                bal = IERC20(replacements[i].token).balanceOf(address(this));
            } else {
                bal = address(this).balance;
                value = bal;
            }

            uint256 offset = replacements[i].offset + 32; // +32 to skip bytes length prefix
            if (offset > callData.length) revert CalldataTooShort(callData.length, offset);

            assembly ("memory-safe") {
                let ptr := add(callData, offset)
                mstore(ptr, or(mload(ptr), bal))
            }
        }

        (ok, out) = target.call{ value: value }(callData);
    }

    // ── Command funding helpers ──────────────────────────────────────────────

    function _pull3009(bytes memory input) internal {
        (
            uint8 src,
            address token,
            uint256 amt,
            uint256 validAfter,
            uint256 validBefore,
            uint8 v,
            bytes32 r,
            bytes32 s
        ) = abi.decode(input, (uint8, address, uint256, uint256, uint256, uint8, bytes32, bytes32));
        IERC20Auth(token).receiveWithAuthorization(
            _source(src),
            address(this),
            amt,
            validAfter,
            validBefore,
            _orderId,
            v,
            r,
            s
        );
    }

    function _pullPermit2Witness(bytes memory input) internal {
        (
            uint8 src,
            address token,
            uint256 amt,
            uint256 nonce,
            uint256 deadline,
            bytes32 inputWitness,
            string memory witnessType,
            bytes memory sig
        ) = abi.decode(input, (uint8, address, uint256, uint256, uint256, bytes32, string, bytes));
        if (inputWitness != _orderId) revert InvalidWitness();
        PERMIT2.permitWitnessTransferFrom(
            IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
            IPermit2.SignatureTransferDetails(address(this), amt),
            _source(src),
            _orderId,
            witnessType,
            sig
        );
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _source(uint8 src) internal view returns (address) {
        return src == 0 ? _orderOwner : msg.sender;
    }

    function _balanceOf(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
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
