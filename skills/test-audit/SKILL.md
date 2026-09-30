---
name: test-audit
description: Audit test value and regression proof. Use when assessing, simplifying, or pruning tests, investigating tautological or misleading assertions, or strengthening regression coverage. Keep the audit within the requested diff or subsystem; ordinary test edits do not imply a whole-suite audit.
license: MIT
metadata:
  source: https://github.com/openclaw/openclaw/tree/80930af448ebabc84174146b56bc106d37fab3b4/.agents/skills/test-audit
  upstream-revision: 80930af448ebabc84174146b56bc106d37fab3b4
---

# Test audit

Improve confidence per test, not the deletion count. Keep distinct contracts,
repair weak assertions, and remove duplication only after identifying the proof
that remains. This skill is language- and runner-independent.

## Scope

Read the repository and scoped instructions. Record the requested scope, base
revision, current changes, and relevant test commands. If revision, history, or
CI metadata is unavailable, record that limitation and identify the supplied
files instead. Preserve unrelated work.
A review-only request produces findings, not edits. An audit does not itself
authorize publishing, merging, or changing CI requirements.

Use the focused workflow below for a diff, test file, or specific regression.
Read [campaign.md](references/campaign.md) only for an explicitly requested
subsystem-wide audit. Do not turn a small test change into a campaign.

## The value bar

For each new, changed, or potentially removable test, answer:

1. What observable behavior or independent contract does it protect?
2. What credible production regression would make it fail?
3. Which existing test already covers that contract, and what distinct risk
   justifies another layer?
4. Does it require an export, injection hook, or wrapper that no production
   caller needs? Prefer exercising the real owner before adding such a seam.

One contract should have a primary test at the strongest practical boundary.
Another layer is useful when it detects a different failure, such as transport
framing, persistence, cancellation, or lifecycle behavior. A mocked unit test and
a real protocol test are not duplicates merely because their names overlap.

Keep independent API, protocol, security, config, migration, storage, platform,
packaging, and default-behavior contracts. Static or slow is not a deletion
reason. Source inspection can be appropriate when it protects a required public
byte or architecture constraint; identifier-only refactors should not break it.

## Find weak proof

Read assertions and parameter rows, not just test names. Look for:

- Expected values computed by the same helper under test; self-comparisons,
  copied declarations, or assertion-free coverage probes.
- Mocks that implement the very behavior being asserted, supply a receipt the
  owner should produce, or impose the ordering the owner should guarantee.
- Private predicate or call-shape assertions already covered by an observable
  behavior test; exact-source checks that merely freeze an implementation.
- Repeated cases whose different inputs all exercise the same mechanism, with
  no distinct boundary, history, or failure mode to justify the matrix.
- Negative cases that pass because an earlier operation cancelled the work,
  removed the item, or tripped another guard before the intended guard ran.
- Tests keeping otherwise unused production code or test-only accessors alive.
- Names promising more than the input and assertions exercise.

These are investigation leads, not automatic deletion rules. Read the complete
candidate, production owner, callers, relevant dependencies, sibling coverage,
history, and CI routing before deciding. For a small audit, focus that reading
on the contracts in question rather than scanning the whole repository.

## Record the decision before editing

Keep a short ledger for each candidate:

- Test name/location and the failure it actually detects.
- Production callers and any test-only seam it keeps alive.
- Relevant history or reason it exists.
- Decision: **retain**, **repair**, **consolidate**, or **delete**.
- For consolidation/deletion: the remaining test that protects each contract,
  or evidence that the contract is obsolete; any source cleanup unlocked.
- Risk and the focused validation command.

If the remaining proof is uncertain, retain the test and report the uncertainty.
Do not delete a baseline failure to make the suite green. Investigate whether it
is a product defect, stale expectation, or environmental failure; fix only what
the task authorizes and record unresolved failures separately.

## Make the proof causal

For a bug fix, run the regression against the pre-fix implementation and the
candidate where feasible, with equivalent fixtures and commands. A compile
error, missing new API, setup failure, or unrelated timeout is not a failing
regression demonstration. Record the actual failure and passing result.

For suspected weak assertions, a narrow fault control can show whether the test
detects its claimed regression: in a disposable checkout or isolated copy, bypass one guard or
alter one production effect, then run the relevant case. Confirm the intended
assertion fails. A fault injection is not a pristine-baseline run; name which
kind of evidence you obtained. If neither can run, report the unproven claim.

Exercise independent guards independently. Start from a valid operation, prove
the target path is reachable, introduce the condition, and assert its observable
outcome. A prior rejection must not make later assertions vacuous. Use controlled
synchronization for races instead of arbitrary sleeps; do not mock the decision
the test is meant to establish.

Keep fault controls isolated from user work. Do not edit source while its test
runner is active. Restore or discard only the control's own changes, verify the
candidate is unchanged, and never commit an injected defect.

## Edit and validate

Consolidate shared setup and carry unique assertions into the remaining tests
before removing duplicates. Remove an unused production seam only after checking
all callers, public exports, and dynamic/configuration consumers. Preserve test
discovery and CI routing when moving cases.

Use the repository's supported runner and resource limits. Run the smallest
affected owner and sibling suites, plus its required formatting, lint, type,
and review gates. Do not import another project's command names or install a new
framework just for this audit. Broaden validation when the change or an observed
failure warrants it; repeat a check only when its relevant inputs changed or a
failure needs investigation.

Review removed coverage against the remaining tests before publishing. For a
substantial deletion or a sensitive contract, use an independent preservation
review when available and authorized. Never weaken assertions, timeouts, or
required gates merely to get green.

## Handoff

Report the contracts improved, low-value categories removed, production seams
simplified, and suspicious tests retained with reasons. Include commands and
results bound to the tested revision, baseline versus fault-control evidence,
unresolved coverage, and test/support versus production line changes. Give the
publication state only if publication was authorized and performed.

Adapted from OpenClaw's test-audit skill and campaign guide at the revision in
the frontmatter. The [upstream MIT notice](references/upstream-license.md) applies
to the adapted material.
