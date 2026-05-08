# Known Issues — Out of Bug Bounty Scope

This document lists findings that we are aware of and that are **not eligible for bug bounty rewards**. They fall into one of three categories:

1. **Intended behavior.** The "issue" is a deliberate design choice and is working as documented.
2. **Known limitation with planned remediation.** We have already evaluated the issue, chosen a mitigation, and have a plan to address it. New reports do not give us new information.
3. **Accepted operational risk.** We have considered the trade-off and decided not to change the system.

If your finding matches one of the entries below, please do not submit it — it will be marked as a duplicate. If you believe your finding is materially different from what is described here (e.g. a new attack path, a higher-impact variant, a missed assumption), please make that delta explicit in your submission.

For findings not covered below, please refer to the bug bounty program's scope and severity guidelines.

---

## How to use this document

1. Search this file for keywords related to your finding.
2. Read the matching entry in full, including its caveats and the "what would still be in scope" notes.
3. If your finding is genuinely a duplicate, please do not submit it.
4. If your finding adds new information, please reference the entry by ID in your submission and explain the delta clearly.

---

## Index

- [KI-001 — Tokens left on `MulticallHandler` are recoverable by anyone](#ki-001--tokens-left-on-multicallhandler-are-recoverable-by-anyone)
- [KI-002 — Tron SP1Helios uses `SP1AutoVerifier` (no-op) instead of a real Succinct verifier](#ki-002--tron-sp1helios-uses-sp1autoverifier-no-op-instead-of-a-real-succinct-verifier)

---

## KI-001 — Tokens left on `MulticallHandler` are recoverable by anyone

**Category:** Intended behavior
**Affected contract:** `contracts/handlers/MulticallHandler.sol`

`MulticallHandler` is a stateless utility designed under the assumption that any tokens delivered to it are consumed in the same transaction. It has no per-user accounting, no admin rescue, and no time-locked sweep — by design. Balances left on the handler are orphaned funds and are recoverable by any caller. If a caller mis-encodes a multicall and leaves tokens behind, that is a caller error, not a protocol bug.

---

## KI-002 — Tron SP1Helios uses `SP1AutoVerifier` (no-op) instead of a real Succinct verifier

**Category:** Known limitation with planned remediation (expected June 2026)
**Affected contracts:** Tron `SP1Helios` (`TM7RW746BsRpoarBGZfwWVnVvhLNK6tBQx`), `SP1AutoVerifier` (`TUsGvWXwp8fhFfJD2Qj3qGUWUFqH4sjm84`), `Universal_SpokePool` (`TDe6gRnHcqZnhn1H5UZQcJ29kmvadFKjb8`)

The Tron `SP1Helios` `verifier` points at `SP1AutoVerifier`, a no-op. `SP1Helios.update()` performs no proof verification, so anyone with `STATE_UPDATER_ROLE` can write arbitrary state into Helios, which `Universal_SpokePool` consumes to authenticate cross-chain admin commands. We are aware of the full attack model, including the bootstrap path where an attacker uses a forged state to grant themselves `STATE_UPDATER_ROLE` or `DEFAULT_ADMIN_ROLE` and decouple control from the original bot key.

The real `SP1VerifierGateway` does not currently work on Tron due to an upstream Tron runtime issue. Pointing Helios at it would brick `update()`. A Tron-side fix is expected by June 2026, after which we will deploy a real verifier, redeploy `SP1Helios` (the `verifier` is `immutable`), and migrate the admin path. In the meantime we keep Tron TVL small and monitor `STATE_UPDATER_ROLE` activity.

---

## Maintenance

When adding a new entry:

1. Pick the next available `KI-NNN` identifier.
2. Use one of the three categories: _Intended behavior_, _Known limitation with planned remediation_, _Accepted operational risk_.
3. State the affected contracts (paths and, where relevant, deployed addresses).
4. Be specific about **what is** out of scope and **what is still** in scope. Vague entries lead to more duplicate submissions, not fewer.
5. Link from the index at the top.

When an entry is resolved (e.g. a planned remediation lands), move it to a `## Resolved` section with the date and a pointer to the change rather than deleting it. This preserves the audit trail for past bug bounty triage decisions.
