---
name: double-check
description: Audit the current solution before it ships. Use when the user says "double check", "/double-check", "is this the highest confidence solution", or wants a last pass for gaps, overengineering, stale assumptions, and negative impact. Excludes implementation and merging.
metadata:
  short-description: Last pass for confidence, gaps, overengineering, and stale assumptions
---

# Double check

Answer this question about the current solution, and act on the answer:

> Is this the highest confidence solution, with no clear gaps, no
> overengineering, incredibly surgical but still efficient with no drop in
> quality or performance, and the least likely to cause any negative impact?
> No drift or staleness in assumptions? Audited a few times over?

First pin what you are auditing. Enumerate the whole change: commits ahead of
the base, staged files, unstaged files, and untracked files. Read that diff
and the files it touches before answering. Do not answer from memory of what
you intended to change.

Check each item and name what you found:

- **Confidence.** Is this the solution you would pick with full information? If a simpler or more certain one exists, name it.
- **Gaps.** Any path, input, caller, or state the change does not handle.
- **Overengineering.** Any abstraction, option, fallback, or file the task does not need.
- **Surgical and efficient.** The change touches only what the task requires, and it adds no cost in quality or performance.
- **Negative impact.** What could break for callers, users, data, or operations if this lands.
- **Stale assumptions.** Any assumption from earlier in the session that the code, docs, or repository state no longer supports. Verify against the current files, not the conversation.
- **Audited.** Ground the verdict in evidence: the diff, the tests and gates that cover it, and any independent review that already exists for this head. A second pass in the same context is not independent, so do not repeat it to manufacture confidence. Invoke an independent review only when the repository requires one.

Then report in a few lines. The verdict is one of three:

- **Yes.** Every item above is checked against evidence and holds.
- **No.** Name each specific failure.
- **Cannot verify.** A required check was skipped, unavailable, or reached no verdict. Name the gap. Never answer yes over missing proof.

State what you changed because of the audit and what remains uncertain.

Fix a defect only when the current request already authorizes edits, and only
within the task's scope. Otherwise report it. A fix invalidates the verdict:
re-read the changed diff and rerun the affected checks before you report.
