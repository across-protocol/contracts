// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import { Order, Step, TypedData, USDFreeIdLib } from "./Interfaces6.sol";
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

/// @dev Executors are untrusted external contracts that perform order-specific logic (swaps, bridges, etc.)
interface IExecutor {
    function execute(address orderOwner, bytes calldata stepMessage, bytes calldata executorMessage) external payable;
}

// ── Order authorization ──────────────────────────────────────────────────────

struct SpendingCap {
    address token;
    uint256 maxAmount;
}

struct Requirement {
    uint8 typ;
    bytes data;
}

struct OrderAuth {
    SpendingCap[] caps;
    Requirement[] requirements;
    uint256 deadline;
}

// ── Requirement types ────────────────────────────────────────────────────────
//   MIN_BALANCE:      (address token, address account, uint256 minAmount)
//   MIN_RECEIVED:     (address token, address account, uint256 minAmount)  — snapshot-based
//   MAX_OWNER_SPENT:  (address token, uint256 maxAmount)                  — snapshot-based

uint8 constant REQ_MIN_BALANCE = 0;
uint8 constant REQ_MIN_RECEIVED = 1;
uint8 constant REQ_MAX_OWNER_SPENT = 2;

// ── Commands ─────────────────────────────────────────────────────────────────

library Commands {
    bytes1 constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 constant COMMAND_TYPE_MASK = 0x7f;

    uint8 constant PULL_ERC20 = 0x00;
    uint8 constant PULL_3009 = 0x01;
    uint8 constant PULL_PERMIT2_WITNESS = 0x02;
    uint8 constant CLAIM_NATIVE = 0x03;

    uint8 constant EXECUTE = 0x10;

    uint8 constant TRANSFER = 0x20;
    uint8 constant SWEEP = 0x21;

    uint8 constant BALANCE_CHECK = 0x30;
}

// ── Step type constants ──────────────────────────────────────────────────────
// STEP_DIRECT:   data = abi.encode(leafHash).         Single step, one EXECUTE.
// STEP_MERKLE:   data = abi.encode(root).             Submitter picks one leaf, one EXECUTE.
// STEP_SEQUENCE: data = abi.encode(bytes32[] leaves).  Ordered list, one EXECUTE per step.

uint8 constant STEP_DIRECT = 0;
uint8 constant STEP_MERKLE = 1;
uint8 constant STEP_SEQUENCE = 2;

// ── OrderGateway ─────────────────────────────────────────────────────────────

contract OrderGateway {
    // ── Errors ──

    error LengthMismatch();
    error InvalidCommand(uint8 command);
    error CommandFailed(uint256 index, bytes reason);
    error NativeOverspend();
    error BalanceTooLow();
    error NonceAlreadyUsed();
    error StepMismatch();
    error StepCountMismatch();
    error StepOverflow();
    error InvalidStepProof();
    error InvalidStepType(uint8 typ);
    error InvalidWitness();
    error OrderAuthRequired();
    error OrderAuthExpired();
    error InvalidOrderAuth();
    error SpendingCapExceeded(address token);
    error NoCapForToken(address token);
    error NotActiveExecutor();
    error RequirementFailed(uint256 index);
    error InvalidRequirementType(uint8 typ);

    // ── Events ──

    event OrderSubmitted(
        bytes32 indexed orderId,
        bytes32 indexed executionId,
        bytes32 stepId, // only set for STEP_MERKLE (reveals which leaf was chosen)
        address indexed orderOwner,
        address submitter
    );

    // ── EIP-712 ──

    bytes32 private constant _SPENDING_CAP_TYPEHASH = keccak256("SpendingCap(address token,uint256 maxAmount)");
    bytes32 private constant _REQUIREMENT_TYPEHASH = keccak256("Requirement(uint8 typ,bytes data)");
    bytes32 private constant _ORDER_AUTH_TYPEHASH =
        keccak256(
            "OrderAuth(bytes32 orderId,SpendingCap[] caps,Requirement[] requirements,uint256 deadline)"
            "Requirement(uint8 typ,bytes data)"
            "SpendingCap(address token,uint256 maxAmount)"
        );

    // ── Immutables ──

    IPermit2 public immutable PERMIT2;
    bytes32 public immutable DOMAIN_HASH;
    bytes32 public immutable EIP712_DOMAIN_SEPARATOR;

    // ── State ──

    uint8 private _locked = 1;
    uint256 private _nativeUsed;
    address private _activeExecutor;
    mapping(bytes32 orderId => bool) public usedNonces;

    modifier nonReentrant() {
        require(_locked == 1);
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit2_, uint32 chainId) {
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

    // ── Entry point ─────────────────────────────────────────────────────────

    /// @param steps     Resolved steps. Length 1 for DIRECT/MERKLE, length N for SEQUENCE.
    /// @param stepProof Merkle proof — only used when stepOrMerkleRoot.typ == STEP_MERKLE.
    function submit(
        Order calldata order,
        OrderAuth calldata auth,
        bytes calldata authSignature,
        Step[] calldata steps,
        bytes32[] calldata stepProof,
        bytes calldata commands,
        bytes[] calldata inputs
    ) external payable nonReentrant {
        uint256 n = commands.length;
        if (inputs.length != n) revert LengthMismatch();

        bytes32 orderId_ = USDFreeIdLib.orderId(DOMAIN_HASH, order);

        if (order.nonce != bytes32(0)) {
            if (usedNonces[orderId_]) revert NonceAlreadyUsed();
            usedNonces[orderId_] = true;
        }

        bool selfSubmit = order.orderOwner == msg.sender;
        if (!selfSubmit) {
            if (authSignature.length == 0) revert OrderAuthRequired();
            _verifyOrderAuth(orderId_, auth, authSignature, order.orderOwner);
        }

        _verifySteps(order.stepOrMerkleRoot, steps, stepProof);

        uint256[] memory snapshots = _snapshotForRequirements(auth.requirements, order.orderOwner);

        bytes[] memory executorMessages = _executeCommands(
            orderId_,
            order.orderOwner,
            steps,
            auth,
            selfSubmit,
            commands,
            inputs
        );

        if (auth.requirements.length > 0) {
            _enforceRequirements(auth.requirements, snapshots, order.orderOwner);
        }

        emit OrderSubmitted(
            orderId_,
            _executionId(orderId_, steps, executorMessages),
            order.stepOrMerkleRoot.typ == STEP_MERKLE ? USDFreeIdLib.stepId(orderId_, steps[0]) : bytes32(0),
            order.orderOwner,
            msg.sender
        );

        _nativeUsed = 0;
    }

    // ── Executor callbacks ──────────────────────────────────────────────────

    function pullTokens(address token, uint256 amount) external {
        if (msg.sender != _activeExecutor) revert NotActiveExecutor();
        _pay(token, msg.sender, amount);
    }

    function availableBalance(address token) external view returns (uint256) {
        return _balanceOf(token, address(this));
    }

    // ── Order auth verification ─────────────────────────────────────────────

    function _verifyOrderAuth(
        bytes32 orderId_,
        OrderAuth calldata auth,
        bytes calldata sig,
        address orderOwner
    ) internal view {
        if (block.timestamp > auth.deadline) revert OrderAuthExpired();

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", EIP712_DOMAIN_SEPARATOR, _orderAuthStructHash(orderId_, auth))
        );

        if (sig.length != 65) revert InvalidOrderAuth();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != orderOwner) revert InvalidOrderAuth();
    }

    function _orderAuthStructHash(bytes32 orderId_, OrderAuth calldata auth) internal pure returns (bytes32) {
        bytes32[] memory capHashes = new bytes32[](auth.caps.length);
        for (uint256 i; i < auth.caps.length; ++i) {
            capHashes[i] = keccak256(abi.encode(_SPENDING_CAP_TYPEHASH, auth.caps[i].token, auth.caps[i].maxAmount));
        }
        bytes32[] memory reqHashes = new bytes32[](auth.requirements.length);
        for (uint256 i; i < auth.requirements.length; ++i) {
            reqHashes[i] = keccak256(
                abi.encode(_REQUIREMENT_TYPEHASH, auth.requirements[i].typ, keccak256(auth.requirements[i].data))
            );
        }
        return
            keccak256(
                abi.encode(
                    _ORDER_AUTH_TYPEHASH,
                    orderId_,
                    keccak256(abi.encodePacked(capHashes)),
                    keccak256(abi.encodePacked(reqHashes)),
                    auth.deadline
                )
            );
    }

    // ── Requirements ────────────────────────────────────────────────────────

    function _snapshotForRequirements(
        Requirement[] calldata reqs,
        address orderOwner
    ) internal view returns (uint256[] memory snapshots) {
        snapshots = new uint256[](reqs.length);
        for (uint256 i; i < reqs.length; ++i) {
            uint8 typ = reqs[i].typ;
            if (typ == REQ_MIN_RECEIVED) {
                (address token, address account, ) = abi.decode(reqs[i].data, (address, address, uint256));
                snapshots[i] = _balanceOf(token, account);
            } else if (typ == REQ_MAX_OWNER_SPENT) {
                (address token, ) = abi.decode(reqs[i].data, (address, uint256));
                snapshots[i] = _balanceOf(token, orderOwner);
            }
        }
    }

    function _enforceRequirements(
        Requirement[] calldata reqs,
        uint256[] memory snapshots,
        address orderOwner
    ) internal view {
        for (uint256 i; i < reqs.length; ++i) {
            uint8 typ = reqs[i].typ;

            if (typ == REQ_MIN_BALANCE) {
                (address token, address account, uint256 minAmount) = abi.decode(
                    reqs[i].data,
                    (address, address, uint256)
                );
                if (_balanceOf(token, account) < minAmount) revert RequirementFailed(i);
            } else if (typ == REQ_MIN_RECEIVED) {
                (address token, address account, uint256 minAmount) = abi.decode(
                    reqs[i].data,
                    (address, address, uint256)
                );
                if (_balanceOf(token, account) < snapshots[i] + minAmount) revert RequirementFailed(i);
            } else if (typ == REQ_MAX_OWNER_SPENT) {
                (address token, uint256 maxAmount) = abi.decode(reqs[i].data, (address, uint256));
                uint256 currentBal = _balanceOf(token, orderOwner);
                if (snapshots[i] > currentBal && snapshots[i] - currentBal > maxAmount) revert RequirementFailed(i);
            } else {
                revert InvalidRequirementType(typ);
            }
        }
    }

    // ── Step verification ───────────────────────────────────────────────────

    function _stepLeaf(Step calldata step) internal pure returns (bytes32) {
        return keccak256(abi.encode(step.salt, step.executor, keccak256(step.message)));
    }

    function _verifySteps(
        TypedData calldata stepOrMerkleRoot,
        Step[] calldata steps,
        bytes32[] calldata proof
    ) internal pure {
        if (stepOrMerkleRoot.typ == STEP_DIRECT) {
            if (steps.length != 1) revert StepCountMismatch();
            if (_stepLeaf(steps[0]) != abi.decode(stepOrMerkleRoot.data, (bytes32))) revert StepMismatch();
        } else if (stepOrMerkleRoot.typ == STEP_MERKLE) {
            if (steps.length != 1) revert StepCountMismatch();
            if (!_verifyProof(proof, abi.decode(stepOrMerkleRoot.data, (bytes32)), _stepLeaf(steps[0])))
                revert InvalidStepProof();
        } else if (stepOrMerkleRoot.typ == STEP_SEQUENCE) {
            bytes32[] memory expectedLeaves = abi.decode(stepOrMerkleRoot.data, (bytes32[]));
            if (steps.length != expectedLeaves.length) revert StepCountMismatch();
            for (uint256 i; i < steps.length; ++i) {
                if (_stepLeaf(steps[i]) != expectedLeaves[i]) revert StepMismatch();
            }
        } else {
            revert InvalidStepType(stepOrMerkleRoot.typ);
        }
    }

    function _verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            hash = hash <= p ? keccak256(abi.encodePacked(hash, p)) : keccak256(abi.encodePacked(p, hash));
        }
        return hash == root;
    }

    // ── Command loop ────────────────────────────────────────────────────────
    // Each EXECUTE command auto-advances to the next step in the steps array.
    // The submitter controls interleaving (funding between steps) but not step order.

    function _executeCommands(
        bytes32 orderId_,
        address orderOwner,
        Step[] calldata steps,
        OrderAuth calldata auth,
        bool selfSubmit,
        bytes calldata commands,
        bytes[] calldata inputs
    ) internal returns (bytes[] memory executorMessages) {
        uint256 n = commands.length;
        uint256[] memory spent = new uint256[](auth.caps.length);
        executorMessages = new bytes[](steps.length);
        uint256 nextStep;

        for (uint256 i; i < n; ++i) {
            bytes1 cmd = commands[i];
            uint8 op = uint8(cmd & Commands.COMMAND_TYPE_MASK);

            bool ok;
            bytes memory out;

            if (op == Commands.EXECUTE) {
                if (nextStep >= steps.length) revert StepOverflow();
                bytes memory execMsg;
                (ok, out, execMsg) = _executeStep(steps[nextStep], orderOwner, inputs[i]);
                executorMessages[nextStep] = execMsg;
                ++nextStep;
            } else {
                (ok, out) = _dispatch(op, inputs[i], orderOwner, orderId_);
                if (ok && !selfSubmit && op <= Commands.PULL_PERMIT2_WITNESS) {
                    _trackOwnerSpend(auth.caps, spent, inputs[i]);
                }
            }

            if (!ok && cmd & Commands.FLAG_ALLOW_REVERT == 0) revert CommandFailed(i, out);
        }
    }

    function _trackOwnerSpend(SpendingCap[] calldata caps, uint256[] memory spent, bytes calldata input) internal pure {
        uint256 src;
        address token;
        uint256 amt;
        assembly {
            src := calldataload(input.offset)
            token := calldataload(add(input.offset, 0x20))
            amt := calldataload(add(input.offset, 0x40))
        }
        if (src != 0) return;

        for (uint256 i; i < caps.length; ++i) {
            if (caps[i].token == token) {
                spent[i] += amt;
                if (spent[i] > caps[i].maxAmount) revert SpendingCapExceeded(token);
                return;
            }
        }
        revert NoCapForToken(token);
    }

    // ── Executor dispatch ───────────────────────────────────────────────────

    function _executeStep(
        Step calldata step,
        address orderOwner,
        bytes calldata input
    ) internal returns (bool ok, bytes memory out, bytes memory executorMessage) {
        uint256 value;
        (value, executorMessage) = abi.decode(input, (uint256, bytes));
        _activeExecutor = step.executor;
        (ok, out) = step.executor.call{ value: value }(
            abi.encodeCall(IExecutor.execute, (orderOwner, step.message, executorMessage))
        );
        _activeExecutor = address(0);
    }

    // ── Funding & token-op dispatch ─────────────────────────────────────────

    function _dispatch(
        uint8 op,
        bytes calldata input,
        address orderOwner,
        bytes32 orderId_
    ) internal returns (bool ok, bytes memory out) {
        ok = true;

        if (op < 0x10) {
            if (op == Commands.PULL_ERC20) {
                (uint8 src, address token, uint256 amt) = abi.decode(input, (uint8, address, uint256));
                IERC20(token).transferFrom(_source(src, orderOwner), address(this), amt);
            } else if (op == Commands.PULL_3009) {
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
                    _source(src, orderOwner),
                    address(this),
                    amt,
                    validAfter,
                    validBefore,
                    orderId_,
                    v,
                    r,
                    s
                );
            } else if (op == Commands.PULL_PERMIT2_WITNESS) {
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
                if (witness != orderId_) revert InvalidWitness();
                PERMIT2.permitWitnessTransferFrom(
                    IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
                    IPermit2.SignatureTransferDetails(address(this), amt),
                    _source(src, orderOwner),
                    witness,
                    witnessType,
                    sig
                );
            } else if (op == Commands.CLAIM_NATIVE) {
                uint256 amt = abi.decode(input, (uint256));
                _nativeUsed += amt;
                if (_nativeUsed > msg.value) revert NativeOverspend();
            } else {
                revert InvalidCommand(op);
            }
        } else if (op < 0x20) {
            revert InvalidCommand(op);
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
            } else {
                revert InvalidCommand(op);
            }
        }
    }

    // ── ID helpers ──────────────────────────────────────────────────────────

    /// @dev Hashes each (executor, stepMessage, executorMessage) tuple, then combines with orderId + submitter.
    function _executionId(
        bytes32 orderId_,
        Step[] calldata steps,
        bytes[] memory executorMessages
    ) internal view returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](steps.length);
        for (uint256 i; i < steps.length; ++i) {
            hashes[i] = keccak256(
                abi.encode(steps[i].executor, keccak256(steps[i].message), keccak256(executorMessages[i]))
            );
        }
        return
            keccak256(
                abi.encode("USDFreeIdLib.ExecutionId.V1", orderId_, msg.sender, keccak256(abi.encodePacked(hashes)))
            );
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _source(uint8 src, address orderOwner) internal view returns (address) {
        return src == 0 ? orderOwner : msg.sender;
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
