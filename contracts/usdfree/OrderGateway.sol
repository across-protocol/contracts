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

uint8 constant REQ_MIN_BALANCE = 0;
uint8 constant REQ_MIN_RECEIVED = 1;
uint8 constant REQ_MAX_OWNER_SPENT = 2;

// ── Commands ─────────────────────────────────────────────────────────────────
// Encoded in submitterInputs.step.message as abi.encode(bytes commands, bytes[] inputs).
// The orderOwner commits to the command sequence by signing over the step (via order.root).

library Commands {
    bytes1 constant FLAG_ALLOW_REVERT = 0x80;
    bytes1 constant COMMAND_TYPE_MASK = 0x7f;

    uint8 constant PULL_ERC20 = 0x00;
    uint8 constant PULL_3009 = 0x01;
    uint8 constant PULL_PERMIT2_WITNESS = 0x02;
    uint8 constant CLAIM_NATIVE = 0x03;

    // EXECUTE input: (uint256 value, bytes executorStepMessage)
    // Calls step.executor.execute(orderOwner, executorStepMessage, submitterInputs.executorMessage)
    uint8 constant EXECUTE = 0x10;

    uint8 constant TRANSFER = 0x20;
    uint8 constant SWEEP = 0x21;

    uint8 constant BALANCE_CHECK = 0x30;
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
    error OrderAuthExpired();
    error AlreadyExecuted();
    error SpendingCapExceeded(address token);
    error NoCapForToken(address token);
    error NotActiveExecutor();
    error RequirementFailed(uint256 index);
    error InvalidRequirementType(uint8 typ);
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
    bytes32 private _authWitness;
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
    }

    // ── Entry point ─────────────────────────────────────────────────────────
    // Commands and inputs are encoded in submitterInputs.step.message:
    //   step.message = abi.encode(bytes commands, bytes[] inputs)
    // The orderOwner commits to the full command sequence via the Merkle root.

    function submit(
        Order calldata order,
        OrderAuth calldata auth,
        Funding calldata orderOwnerFunding,
        SubmitterInputs calldata submitterInputs
    ) external payable nonReentrant {
        if (block.timestamp > auth.deadline) revert OrderAuthExpired();

        _orderId = USDFreeIdLib.orderId(DOMAIN_HASH, order);
        _orderOwner = order.orderOwner;
        _authWitness = _computeAuthWitness(_orderId, auth);

        if (order.nonce != bytes32(0)) {
            if (usedNonces[_orderId]) revert NonceAlreadyUsed();
            usedNonces[_orderId] = true;
        }

        bool selfSubmit = order.orderOwner == msg.sender;
        if (!selfSubmit && orderOwnerFunding.funding.length == 0) revert OrderAuthRequired();

        if (!_verifyProof(submitterInputs.proof, order.root, _stepLeaf(submitterInputs.step)))
            revert InvalidStepProof();

        // ── Process funding ──
        uint256[] memory spent = new uint256[](auth.caps.length);
        if (orderOwnerFunding.funding.length > 0) {
            _processFunding(orderOwnerFunding, true, auth.caps, spent, selfSubmit);
        }
        if (submitterInputs.funding.funding.length > 0) {
            _processFunding(submitterInputs.funding, false, auth.caps, spent, selfSubmit);
        }

        uint256[] memory snapshots = _snapshotForRequirements(auth.requirements, order.orderOwner);

        // ── Decode and execute commands from step.message ──
        (bytes memory commands, bytes[] memory inputs) = abi.decode(submitterInputs.step.message, (bytes, bytes[]));
        if (inputs.length != commands.length) revert LengthMismatch();
        _executeCommands(submitterInputs, auth.caps, selfSubmit, spent, commands, inputs);

        if (auth.requirements.length > 0) {
            _enforceRequirements(auth.requirements, snapshots, order.orderOwner);
        }

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
        _authWitness = bytes32(0);
    }

    // ── Auth witness ────────────────────────────────────────────────────────

    function _computeAuthWitness(bytes32 orderId_, OrderAuth calldata auth) internal pure returns (bytes32) {
        return
            keccak256(abi.encode(orderId_, _hashCaps(auth.caps), _hashRequirements(auth.requirements), auth.deadline));
    }

    function _hashCaps(SpendingCap[] calldata caps) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](caps.length);
        for (uint256 i; i < caps.length; ++i) {
            h[i] = keccak256(abi.encode(caps[i].token, caps[i].maxAmount));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashRequirements(Requirement[] calldata reqs) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](reqs.length);
        for (uint256 i; i < reqs.length; ++i) {
            h[i] = keccak256(abi.encode(reqs[i].typ, keccak256(reqs[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    // ── Executor callbacks ──────────────────────────────────────────────────

    function pullTokens(address token, uint256 amount) external {
        if (msg.sender != _activeExecutor) revert NotActiveExecutor();
        _pay(token, msg.sender, amount);
    }

    function availableBalance(address token) external view returns (uint256) {
        return _balanceOf(token, address(this));
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

    function _verifyProof(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        bytes32 hash = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 p = proof[i];
            hash = hash <= p ? keccak256(abi.encodePacked(hash, p)) : keccak256(abi.encodePacked(p, hash));
        }
        return hash == root;
    }

    // ── Funding processing ──────────────────────────────────────────────────

    function _processFunding(
        Funding calldata funding,
        bool isOwner,
        SpendingCap[] calldata caps,
        uint256[] memory spent,
        bool selfSubmit
    ) internal {
        address from = isOwner ? _orderOwner : msg.sender;
        for (uint256 i; i < funding.funding.length; ++i) {
            TypedData calldata item = funding.funding[i];
            _processFundingItem(item, from);
            if (isOwner && !selfSubmit) _trackFundingSpend(caps, spent, item);
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
            _authWitness,
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
            _authWitness,
            witnessType,
            sig
        );
    }

    function _trackFundingSpend(
        SpendingCap[] calldata caps,
        uint256[] memory spent,
        TypedData calldata item
    ) internal pure {
        (address token, uint256 amt) = abi.decode(item.data, (address, uint256));
        for (uint256 i; i < caps.length; ++i) {
            if (caps[i].token == token) {
                spent[i] += amt;
                if (spent[i] > caps[i].maxAmount) revert SpendingCapExceeded(token);
                return;
            }
        }
        revert NoCapForToken(token);
    }

    // ── Command loop ────────────────────────────────────────────────────────

    function _executeCommands(
        SubmitterInputs calldata si,
        SpendingCap[] calldata caps,
        bool selfSubmit,
        uint256[] memory spent,
        bytes memory commands,
        bytes[] memory inputs
    ) internal {
        bool executed;

        for (uint256 i; i < commands.length; ++i) {
            bytes1 cmd = commands[i];
            uint8 op = uint8(cmd & Commands.COMMAND_TYPE_MASK);
            bool ok;
            bytes memory out;

            if (op == Commands.EXECUTE) {
                if (executed) revert AlreadyExecuted();
                (ok, out) = _executeStep(si.step, si.executorMessage, inputs[i]);
                executed = true;
            } else {
                (ok, out) = _dispatch(op, inputs[i]);
                if (ok && !selfSubmit && op <= Commands.PULL_PERMIT2_WITNESS) {
                    _trackOwnerSpend(caps, spent, inputs[i]);
                }
            }

            if (!ok && cmd & Commands.FLAG_ALLOW_REVERT == 0) revert CommandFailed(i, out);
        }
    }

    function _trackOwnerSpend(SpendingCap[] calldata caps, uint256[] memory spent, bytes memory input) internal pure {
        (uint8 src, address token, uint256 amt) = abi.decode(input, (uint8, address, uint256));
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
        bytes calldata executorMessage,
        bytes memory input
    ) internal returns (bool ok, bytes memory out) {
        // input: (uint256 value, bytes executorStepMessage)
        // executorStepMessage = static instructions from orderOwner for the executor
        // executorMessage = dynamic data from submitter
        (uint256 value, bytes memory executorStepMessage) = abi.decode(input, (uint256, bytes));
        _activeExecutor = step.executor;
        (ok, out) = step.executor.call{ value: value }(
            abi.encodeCall(IExecutor.execute, (_orderOwner, executorStepMessage, executorMessage))
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
            _authWitness,
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
        if (inputWitness != _authWitness) revert InvalidWitness();
        PERMIT2.permitWitnessTransferFrom(
            IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(token, amt), nonce, deadline),
            IPermit2.SignatureTransferDetails(address(this), amt),
            _source(src),
            _authWitness,
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
