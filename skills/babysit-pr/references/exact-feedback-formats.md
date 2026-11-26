# Exact bot feedback formats

The predicates recognize complete informational bodies, not review outcomes:

- Codex review containers permit one exact leading `codex-review-receipt:v1`
  marker. The full normalized boilerplate must still match. The paired
  address-feedback inventory uses the same body rule and its own Codex-author
  join. Inline findings, direct dispositions, thread resolution and sign-offs
  remain independent. A container on an old revision is not a current approval.

Unknown versions, malformed markers, extra prose and mixed findings remain
feedback. `tests/exact-feedback-formats_test.py` exercises the captured Codex
container through production consumers offline. Existing poller and paired
inventory suites cover unresolved, unanswered, reopened and dispositioned
inline findings.

These source tests do not establish live PR readiness or reviewer requirements.
