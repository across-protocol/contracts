// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Step, Funding, TypedData, SubmitterInputs, USDFreeIdLib } from "./Interfaces.sol";
import { IERC20Auth } from "../external/interfaces/IERC20Auth.sol";

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
}

interface IExecutor {
    function execute(address orderOwner, bytes calldata stepMessage, bytes calldata executorMessage) external payable;
}

// ── Commands ─────────────────────────────────────────────────────────────────
// Command byte layout:
//   Bit 7 (0x80): FLAG_ALLOW_REVERT — failure doesn't revert the tx
//   Bit 6 (0x40): FLAG_SUBMITTER_INPUT — input comes from submitter (executorMessage), not owner (step.message)
//   Bits 0-5:     command type (0x00–0x3f)
//
// step.message encodes the owner's plan:
//   abi.encode(bytes executorStepMessage, bytes commands, bytes[] ownerInputs)
//
// executorMessage encodes the submitter's contributions:
//   abi.encode(bytes executorDynamicMessage, bytes[] submitterInputs)
//
// The owner defines the full command sequence and marks which inputs the submitter provides.
// This is the owner's auth — committed to via the Merkle root they sign over.

library Commands {
    bytes1 constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 constant FLAG_SUBMITTER_INPUT = 0x40;
    bytes1 constant COMMAND_TYPE_MASK = 0x3f;

    uint8 constant PULL_ERC20 = 0x00;
    uint8 constant PULL_3009 = 0x01;
    uint8 constant PULL_PERMIT2_WITNESS = 0x02;
    uint8 constant CLAIM_NATIVE = 0x03;

    // EXECUTE input: (uint256 value)
    // Calls step.executor.execute(orderOwner, executorStepMessage, executorDynamicMessage)
    // Input: (uint256 value)
    uint8 constant EXECUTE = 0x10;

    // Delegatecalls into an adapter contract (runs adapter code in gateway context).
    // Input: (address adapter, bytes data)
    // The adapter can directly approve/transfer tokens from the gateway's balance.
    // Adding a new bridge = deploying a new adapter. No gateway changes needed.
    uint8 constant CALL_ADAPTER = 0x11;

    uint8 constant TRANSFER = 0x20;
    uint8 constant SWEEP = 0x21;

    // Non-reverting balance assertion (use without FLAG_ALLOW_REVERT for hard requirements)
    uint8 constant BALANCE_CHECK = 0x30;
    // Record a balance for later delta comparison. Input: (uint8 slotId, address token, address account)
    uint8 constant SNAPSHOT_BALANCE = 0x31;
    // Check balance change since snapshot. Input: (uint8 slotId, address token, address account, int256 minDelta)
    // Reverts-style like BALANCE_CHECK (non-reverting, use without FLAG_ALLOW_REVERT for hard requirements)
    uint8 constant CHECK_DELTA = 0x32;
}

// ── OrderGateway ─────────────────────────────────────────────────────────────

contract OrderGateway {
    // ── Errors ──

    error LengthMismatch();
    error InvalidCommand(uint8 command);
    error CommandFailed(uint256 index, bytes reason);
    error NativeOverspend();
    error BalanceTooLow();
    error NonceAlreadyUsed();
    error InvalidStepProof();
    error InvalidWitness();
    error OrderAuthRequired();
    error AlreadyExecuted();
    error NotActiveExecutor();
    error InvalidFundingType(uint8 typ);

    // ── Events ──

    event OrderSubmitted(
        bytes32 indexed orderId,
        bytes32 indexed executionId,
        bytes32 stepId,
        address indexed orderOwner,
        address submitter
    );

    // ── Immutables ──

    IPermit2 public immutable PERMIT2;
    bytes32 public immutable DOMAIN_HASH;

    // ── State ──

    uint8 private _locked = 1;
    uint256 private _nativeUsed;
    address private _activeExecutor;
    address private _orderOwner;
    bytes32 private _orderId;
    mapping(bytes32 orderId => bool) public usedNonces;
    // Snapshots for delta-based requirements. slotId => balance at snapshot time.
    // Cleared at end of submit. slotId lets owners track multiple tokens independently.
    mapping(uint8 slotId => uint256) private _snapshots;

    modifier nonReentrant() {
        require(_locked == 1);
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit2_, uint32 chainId) {
        PERMIT2 = IPermit2(permit2_);
        DOMAIN_HASH = USDFreeIdLib.domainHash(chainId, address(this));
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

        bool selfSubmit = order.orderOwner == msg.sender;
        if (!selfSubmit && orderOwnerFunding.funding.length == 0) revert OrderAuthRequired();

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
    }

    // ── Command execution ───────────────────────────────────────────────────
    // Decodes the owner's plan from step.message and the submitter's contributions from executorMessage.
    // Each command pulls its input from ownerInputs or submitterInputs based on FLAG_SUBMITTER_INPUT.

    function _executeFromStep(SubmitterInputs calldata si) internal {
        // Owner's plan: executor static message + command sequence + owner-provided inputs
        (bytes memory executorStepMsg, bytes memory commands, bytes[] memory ownerInputs) = abi.decode(
            si.step.message,
            (bytes, bytes, bytes[])
        );

        // Submitter's contributions: executor dynamic message + submitter-provided inputs
        (bytes memory executorDynMsg, bytes[] memory subInputs) = abi.decode(si.executorMessage, (bytes, bytes[]));

        uint256 ownerIdx;
        uint256 subIdx;
        bool executed;

        for (uint256 i; i < commands.length; ++i) {
            bytes1 cmd = commands[i];
            uint8 op = uint8(cmd & Commands.COMMAND_TYPE_MASK);

            // Select input source based on FLAG_SUBMITTER_INPUT
            bytes memory input;
            if (cmd & Commands.FLAG_SUBMITTER_INPUT != 0) {
                input = subInputs[subIdx++];
            } else {
                input = ownerInputs[ownerIdx++];
            }

            bool ok;
            bytes memory out;

            if (op == Commands.EXECUTE) {
                if (executed) revert AlreadyExecuted();
                (ok, out) = _executeStep(si.step, executorStepMsg, executorDynMsg, input);
                executed = true;
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
    //   typ 0 (ERC20):           data = (address token, uint256 amount)
    //   typ 1 (3009):            data = (address token, uint256 amount, uint256 validAfter, uint256 validBefore, uint8 v, bytes32 r, bytes32 s)
    //   typ 2 (PERMIT2_WITNESS): data = (address token, uint256 amount, uint256 nonce, uint256 deadline, string witnessType, bytes sig)

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

    function _executeStep(
        Step calldata step,
        bytes memory executorStepMsg,
        bytes memory executorDynMsg,
        bytes memory input
    ) internal returns (bool ok, bytes memory out) {
        uint256 value = abi.decode(input, (uint256));
        _activeExecutor = step.executor;
        (ok, out) = step.executor.call{ value: value }(
            abi.encodeCall(IExecutor.execute, (_orderOwner, executorStepMsg, executorDynMsg))
        );
        _activeExecutor = address(0);
    }

    // ── Command dispatch ────────────────────────────────────────────────────

    function _dispatch(uint8 op, bytes memory input) internal returns (bool ok, bytes memory out) {
        ok = true;

        if (op < 0x10) {
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
            } else {
                revert InvalidCommand(op);
            }
        } else if (op < 0x20) {
            if (op == Commands.CALL_ADAPTER) {
                (address adapter, bytes memory data) = abi.decode(input, (address, bytes));
                (ok, out) = adapter.delegatecall(data);
            } else {
                revert InvalidCommand(op);
            }
        } else if (op < 0x30) {
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
        } else {
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
