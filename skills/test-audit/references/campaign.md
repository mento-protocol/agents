# Subsystem test audit

Use this guide only for an explicitly requested audit of a subsystem's entire
test surface. The value and retention rules in [SKILL.md](../SKILL.md) still
apply. A campaign is not a target number of deletions.

## Establish the baseline

Pin a base revision. Inventory the subsystem's tests, support files, integration
fixtures, and relevant cases owned by shared modules. Record baseline results
and test/support versus production line counts. Keep failures and unavailable
checks visible; do not classify a failing case as junk without diagnosis.

Group the inventory by production responsibility. If independent agents are
available and authorized, assign read-only discovery by boundary and give every
test one owner. Otherwise use the same grouping sequentially. Serialize edits
to shared fixtures through one owner.

## Plan what remains

Each declaration or distinct parameter row receives a ledger decision:

- **Retain:** name the contract and regression it catches.
- **Repair:** retain the contract but correct weak or unreachable assertions.
- **Consolidate:** name the remaining test that will receive its unique proof.
- **Delete:** identify stronger remaining proof or an obsolete contract.

Then review the layers as a whole. Choose the primary remaining suite per
contract; a table of individually plausible deletions can still remove all
coverage of a behavior. Prefer a real owner or protocol boundary with controlled
external dependencies when a mocked collaborator merely repeats its behavior.
Record the unique assertions to transfer and test-only source seams to remove.

## Apply and check preservation

Work in coherent batches. Transfer unique proof before deleting its old owner,
update test discovery and CI routing, and run the affected suites. Keep unrelated
product fixes separate. A newly discovered defect is repaired only within the
user's authorized scope; otherwise report it as a follow-up.

For substantial removals, obtain an independent comparison of removed contracts
against their remaining tests when available and authorized. If independent
review is unavailable, report that limitation and perform the comparison
directly. Reviewers need the baseline and candidate, not just a deletion count.

When preservation review finds a gap, restore its contract with a test that
demonstrably catches the missing behavior. Use a pre-fix run for a repaired bug,
or an isolated one-fault control for an assertion gap, following SKILL.md. Record
the distinction and any unexecuted proof; no deletion quota overrides it.

## Reconcile and finish

Follow the repository's branch-update policy and preserve published history.
If upstream changed a removed test, inspect the new contract and port unique
coverage to its remaining owner rather than blindly keeping the deletion.
Rerun affected proof and required gates on the reconciled candidate.

Report baseline/final counts, decisions and remaining test owners, preservation
gaps and their controls, product defects, and checks not run. Report a full
subsystem pass only if every in-scope suite actually ran successfully.
