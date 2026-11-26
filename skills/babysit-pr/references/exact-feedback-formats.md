# Exact bot feedback formats

The predicates recognize complete informational bodies, not review outcomes:

- Codex review containers permit one exact leading `codex-review-receipt:v1`
  marker. The full normalized boilerplate must still match. The paired
  address-feedback inventory uses the same body rule and its own Codex-author
  join. Inline findings, direct dispositions, thread resolution and sign-offs
  remain independent. A container on an old revision is not a current approval.
- A claude-code-action review summary is free-form model text, so it has no
  full-body shape. It is informational only when it comes from
  `github-actions[bot]`, starts with the action's `**Claude finished @<login>'s
  task in <time>** —— [View job](<run URL>)` header, ends with the exact line
  `Review result: LGTM, no findings`, and carries no `[P1]`, `[P2]` or `[P3]`
  tag. The repository's review prompt asks for that line on a clean review only;
  a repository whose prompt does not ask for it keeps every summary actionable.

Unknown versions, malformed markers, extra prose and mixed findings remain
feedback. `tests/exact-feedback-formats_test.py` exercises the captured Codex
container and a captured Claude summary through production consumers offline. Existing poller and paired
inventory suites cover unresolved, unanswered, reopened and dispositioned
inline findings.

These source tests do not establish live PR readiness or reviewer requirements.
