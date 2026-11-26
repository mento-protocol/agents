# Finding classes

A finding class names one defect mechanism. A single review rule or check
could target it. Test: a reviewer who reads only the slug knows what to look
for in an unrelated file of the same repository.

## Rules

- Give each finding exactly one class. When a finding names more than one
  defect, class the one in its summary or first sentence.
- Write the slug in kebab-case, two to five words. Name the defect mechanism:
  what is wrong and why it fails. Do not name the file, the product, or the
  fix.
- Reuse before you invent. Read the classes the repository already uses: its
  catalogue (`docs/review-classes.md`, "The catalogue" below), its
  `docs/review.md` tags and its earlier review records. Reuse a slug or an
  alias that names the same mechanism. Invent a new slug only when none does.
- Do not split one mechanism into several slugs because it appears in
  different files or languages. Do not merge two mechanisms because they
  share a symptom, such as a crash or a wrong number.
- Do not put a file name, function name, variable name, product name, PR
  number, or repository name in a slug. `stale-readme-step` is allowed;
  `stale-mac-setup-readme` is not.
- Do not use a bare area or severity word as the whole slug. These are too
  broad: `bug`, `logic`, `logic-error`, `omission`, `correctness`,
  `contract`, `security`, `docs`, `documentation`, `error-handling`,
  `robustness`, `edge-case`, `test`, `tests`, `validation`,
  `input-validation`, `race`, `performance`. Qualify the word with the
  mechanism: `unvalidated-model-output-type`, not `input-validation`.

The list above is `BARE_CLASS_WORDS` in `../scripts/validate_record.py`. The
validator rejects a record whose class equals one of these words. Keep this
list and the constant equal.

## Examples

`unbounded-subprocess`, `orphaned-child-process`, `exit-status-masked`,
`symlink-followed-on-write`, `result-not-bound-to-input`,
`claim-accepted-without-evidence`, `output-drops-recorded-fields`,
`identity-hash-misses-input`, `policy-duplicated-outside-entry`,
`test-samples-miss-property`.

## Where classes live

- **The review record.** The review skill writes the slug in each finding's
  `class` field ([tooling](tooling.md), "The review record"). The schema
  pattern is `^[a-z][a-z0-9]*(-[a-z0-9]+){1,6}$`: two to seven words, so
  that older longer slugs stay valid. Older records have no `class` field.
- **The review guide.** Each bullet in a repository's `docs/review.md` ends
  with `(class: <slug>)`. Bullets that share a mechanism share a slug.
- **The catalogue.** A repository's `docs/review-classes.md` lists its
  classes, one line each ("The catalogue" below). Every guide tag resolves to
  a catalogue slug or alias.
- **The retro.** The `retro` skill classes the fixed findings of its
  session's PRs. A class that repeats becomes a review-guide candidate
  (retro Step 3, "Repeated finding classes go to the review guide").

## The catalogue

A repository keeps its classes in `docs/review-classes.md`, beside the review
guide. Each bullet holds one slug, a one-sentence definition that names the
mechanism, the date of first use, and any aliases:

```text
- `slug`: <Definition>. First seen <yyyy-mm-dd>. Aliases: `a`, `b`.
```

The definition is one sentence that starts with a capital letter. Omit
`Aliases:` when there are none.

- The review skill reads the catalogue from the same base commit and under
  the same rules as the guide (`../SKILL.md` §1): a regular tracked file in
  that commit's tree. Absence is normal; an inspection failure is reported as
  unavailable.
- Reuse means: reuse a catalogue slug or alias when it names the finding's
  mechanism. An alias counts as the slug on its line.
- When no catalogue slug or alias names the mechanism, coin a slug per the
  rules above and use it in the record. List it in the review report under a
  "New classes" heading, with a one-line definition.
- A review does not edit the catalogue. The PR that adds a guide bullet with
  a new slug adds its catalogue line in the same change; the `retro` skill
  adds lines and merges near-synonyms (retro Step 3).
- A repository that starts its catalogue copies the seed classes below that
  match its defects, each with its first-seen date.

## Seed classes

These classes repeated across PRs in a retrodiction over the fixed review
findings of six repositories; the definitions are adapted from its labels.
They are agent-proposed, not human-reviewed.

- `check-then-act-race`: A state check and the action that depends on it are
  separated, so a concurrent change invalidates the check.
- `claim-accepted-without-evidence`: A complete, verified or conclusion
  status is accepted although the supporting evidence is absent, empty or
  does not show it.
- `error-misclassified-exit-code`: An error or outcome is mapped to the wrong
  status or exit code, which discards its original classification.
- `failure-counted-as-success`: An error, failed, missing or ungraded result
  is not detected and is counted as a successful or completed one.
- `generated-command-incorrect`: A command that a tool prints or installs for
  later execution lacks required arguments, overrides or safe quoting, so
  running it fails or does something else.
- `hand-parser-misreads-valid-syntax`: A hand-written parser of a formal
  language (YAML, shell) misreads valid input, so the input is mis-measured,
  mistyped or rejected.
- `incomplete-input-accepted-as-complete`: A partial, short or missing input
  set is accepted as complete, so unchecked items pass.
- `inexact-set-comparison`: A count, sum or subset check stands in for an
  exact per-member set comparison, so a wrong or missing member passes.
- `output-drops-recorded-fields`: A summary, projection or rendered view
  drops recorded fields that readers need to interpret it.
- `overbroad-string-match`: A regex, substring or pattern match is
  unanchored, greedy or position-insensitive and matches more than intended.
- `read-failure-treated-as-absent`: A failed or partial read of
  authoritative state is treated as empty or absent and drives a destructive
  action.
- `result-not-bound-to-input`: A result or report is accepted without a check
  that it was produced from the requested input, plan or range.
- `special-file-not-rejected`: A FIFO, device or other special file is not
  rejected and blocks a read or escapes a digest.
- `symlink-followed-on-write`: A write, move, copy or delete follows a
  symlink at the destination or in its parents and changes data outside the
  intended tree.
- `test-passes-for-wrong-reason`: A counterexample test fails on several
  conditions or returns incomplete, so it passes without exercising the
  condition it names.
- `unchecked-path-type-collision`: An existence or type test accepts an
  existing destination of the wrong type (directory, regular file, special
  file, dangling symlink), so a collision passes.
- `weak-test-oracle`: A test oracle checks only part of the output, so a
  mutated or wrong result still passes.

## Evidence

Two model labellers applied these rules independently to 105 fixed findings
of one repository. They agreed on 86.7% of the classes (Cohen's kappa 0.861).
Slugs are agent-proposed, not human-reviewed.
