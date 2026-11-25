# Existing review tooling

The second-model passes below apply only where their tool exists, the checkout is
trusted (the user's own or their team's repository, not a third-party or
caller-supplied checkout), and disclosure of the diff to the second model's
provider is approved (`../SKILL.md` §6). Everywhere else a careful direct read is
the whole capability. Check the tool exists before you plan around it. The
exceptions are "The bounded re-review" below, which applies to every review in a
Claude session, and "The review record", which applies to every run, in every
repository.

`$REVIEW_SKILL_DIR` below is the directory that holds this skill's `SKILL.md`,
resolved from the installed skill rather than from the reviewed checkout.

Tool output does not replace §3–§4 of `SKILL.md`. Their output is _input_ to your review, and
you verify every finding they produce against the real code before it reaches the user or
a file gets edited. Review models have been observed emitting confident findings about code that
was never there.

**When Codex is unavailable.** With no `codex` on PATH, a catalog lookup that fails, or
no completed report, the review runs Claude-only. The report then carries this line, on
its own line, word for word:

```text
independent second-model review: skipped, Codex unavailable
```

A caller such as `ship-pr` treats that line as a stated gap, not a blocker, unless the
user or trusted repository policy requires the second-model pass.

---

## A repository closeout command

Some repositories document their own second-model closeout, a command that runs
`codex exec review` (or another reviewer) over the diff from a base ref and writes
the report to a file. Where one exists, run it instead of the direct pass in the next
section, with the flags its documentation names.

- Pass the PR's real base, for example
  `--base "origin/$(gh pr view --json baseRefName --jq .baseRefName)"`. Do not let it
  infer a default branch for a stacked PR.
- After a base integration (a merge of `main` into the branch), run it on **both axes**
  against the same final head: once against the integrated base OID and once against the
  pre-merge head OID. The second axis catches a conflict resolution that dropped branch
  behaviour. After a review fix, run both axes again on the new head.
- Check the command's completion contract before trusting its exit code. A runner that
  returns 0 for any nonempty body without a findings marker lets refusals and partial
  answers pass, and such a 0 does not establish a completed review. Read finding reports
  and relay failure reasons. Manual inspection does not convert an incomplete required
  review into a completed closeout.
- Inline the report text into the review instead of handing over its path: the paired
  pass reads the whole report.
- If the command fingerprints the tree and reports that it moved, stage new files first,
  do not edit mid-run, and rerun rather than report a partial result.
- When its own fetch of the base fails in the sandbox, fetch in the sandbox with an
  explicit refspec, so the tracking ref moves even in a single-branch clone:
  `git fetch "$BASE_REMOTE" "+refs/heads/$baseRefName:refs/remotes/$BASE_REMOTE/$baseRefName"`.
  Then run the command unsandboxed (the reviewer needs network) with its no-fetch option
  and that base, the remote and branch preflight bound.
- A large diff can run for a long time: a short prose diff takes minutes, a PR with
  hundreds of files much longer. Use a foreground or managed-background call that
  retains a process handle and supports polling, with a suitable timeout. Never detach
  with shell `&`. Keep the exit status, the report path and the full report. Process
  exit alone does not establish a completed review.
- Trust boundary. `codex` reads `AGENTS.md`, `CLAUDE.md`, `.codex`, and `.agents` from
  the checkout under review, so the branch can rewrite the policy reviewing it; read the
  instruction files the run will see, not only the touched ones, before trusting the
  report. A diff that changes the closeout script or its package alias runs the
  candidate's own review tool: review those changes from a trusted checkout at the base.
  The reviewer runs under the operator's own `codex` configuration and can read `HOME`;
  it is not an isolated runtime, and the report is unscanned model output that may quote
  credential-shaped diff content.
- Source review only: it runs no tests. With no `codex` on PATH, skip it, run the review
  alone, and report the line under "When Codex is unavailable". Inside an active Codex
  session it cannot run, because nested `codex exec` is unavailable; run it from a Claude
  session or an operator shell.

---

## Why the second model is paired, never trusted alone

Measured on real PRs against the defects later reviewers found, a Sol finder pass
followed by a Claude verify-and-extend pass recalled clearly more defects than any
single reviewer alone, including the strongest Claude model at maximum effort. The
pairing is the value: the Claude leg both filters the Codex report's wrong claims and
adds findings it missed, and it compensates for a weaker finder. Raising either leg
above `high` effort bought no measurable recall. So: run the second-model pass, then do
the verification and extension yourself. Consuming the report without re-checking it,
or skipping it on non-trivial changes, both measurably lose recall.

- The pass reviews the **local checkout** against its base. For a remote PR that isn't
  checked out it would review a different body of code than the one under review; in that
  situation skip it entirely rather than merging its findings in.
- Retain an observable process handle until exit. Use the runtime's supported
  foreground or managed-background polling. Never detach with shell `&` or
  return while a required review is still running.
- Never let it apply fixes.

---

## `codex exec review` (trusted repositories without a closeout)

The same pass without a closeout command, only under the conditions at the top of
this file: `codex` runs under the operator's configuration and reads the whole disk,
so a third-party or caller-supplied checkout, whose instruction files `codex` loads,
never gets this pass. Measured on frozen PR heads, the pair found about half again as
many later-found defects as this skill alone, with fewer false findings, at about 1.4×
the wall time. The Codex half varies on identical input, so the gain is real but
uneven. Run it before this skill's own pass. First look up the model, then run the
review with the printed name in place of `<sol-model>`:

```text
python3 "$REVIEW_SKILL_DIR/scripts/codex-sol-model.py"
codex exec review --base <base> -m <sol-model> -c 'model_reasoning_effort="high"' -c 'sandbox_mode="read-only"' > <report> 2> <report>.stderr.log
```

- The lookup picks the newest available Sol. It reads the account's Codex model
  catalog (`$CODEX_HOME/models_cache.json`, by default `~/.codex/models_cache.json`)
  and prints the highest `gpt-<version>-sol` model that the catalog lists as
  visible. Pass the printed name literally; do not wrap the lookup in `$(...)`,
  because a Claude session's shell guard can refuse that command. The lookup
  does not read the Codex default model, so a model chosen for interactive
  sessions does not change the review model. On a non-zero exit, do not run
  Codex with its default model or a guessed name: the second model cannot
  run, the fallback in `../SKILL.md` §7 applies, and the report carries the line
  under "When Codex is unavailable". The report names the model that ran. Sol
  versions newer than the measured one are unmeasured.
- Select the mode from the pinned target: `--base <base>` for a branch against
  its resolved base ref (`origin/<baseRefName>`, fetched first), `--commit <sha>`
  for one commit, `--uncommitted` for staged, unstaged and untracked work.
  `--base` takes no custom prompt and does not see untracked files.
- Run it from a working tree that is exactly the pinned target: a clean
  temporary worktree at the head when unrelated edits exist. Record
  `git rev-parse HEAD` and the base SHA before and after the run, with the
  report. For `--uncommitted` the SHAs do not identify the reviewed state:
  also record a fingerprint of the index, the tracked working tree and the
  in-scope untracked files' contents (for example the sha256 over
  `git diff HEAD --binary` plus `git ls-files -o --exclude-standard -z |
xargs -0 shasum -a 256`). A change in any recorded value invalidates the
  pass.
- Write the report and the stderr log outside the repository (the session
  scratchpad), or under `.reviews/` only where `git check-ignore` confirms it is
  ignored; never into the commit. The report is unscanned model output.
- Run it as a managed background call, unsandboxed where the sandbox blocks
  the network; retain the handle and wait for exit, because a foreground call
  can hit the runtime's timeout (allow up to about 45 minutes for a large
  diff). Start this skill's own pass only after it exits, with its findings in
  hand, as the measurement ran it; pinning the target and reading the diff
  meanwhile is fine. Success is a nonempty completed report: Codex exits 0 even
  on provider failure. A completed report that lists no findings is valid (the
  first half found nothing); empty output or a timeout is incomplete coverage
  ("Combining two sources" below), and the report then carries the line under
  "When Codex is unavailable".
- Then verify every finding against the cited code (confirmed, refuted, or
  unverifiable; keep unverifiable ones as suspected, drop refuted ones and
  name them) and run this skill's own pass with the Codex findings as a hint
  of where that reviewer stopped, not as a boundary. The review result is the
  union, and the report names each finding's source.
- The trust boundary above applies unchanged: `codex` loads the installed
  `review` skill and the checkout's instruction files, runs under the
  operator's configuration and reads the whole disk.
- Skip it, and say so, with no `codex` on PATH or for a remote PR that is not
  checked out. Inside `codex exec review` (you are the second half) review
  alone. In a Codex session run the mirror below instead: nested `codex exec`
  is unavailable, and the second model does not pair with itself.

### The mirror in a Codex session

In a Codex session the reviewer is Codex, so the pairing runs the other way: a
Claude review first, then the session verifies each of its findings and runs
this skill's own pass. Measured against Codex alone, the mirror found about twice
as many known defects at about 2.4× the wall time, but made more false findings on
clean controls. The consequence is on the verifier: open the cited code for every
claim in the Claude report and drop what the code refutes. Write the diff to a file
first, then run the reviewer from the checkout with the reviewed branch's
configuration kept out.

Create a fresh input directory. After creating it and before launching Claude,
export each present guide or catalogue from the pinned base into it. Apply
[review step 1](../SKILL.md#1-pin-the-target-before-you-read-anything)'s
regular-file and absence checks. In the prompt, replace `<base inputs>` with
each repository path, its status, and its exported name when present. Give the
reason for an unavailable file. Keep reports outside this directory. Remove
temporary copies after retaining any evidence required for the review record.

`--model opus` is the runtime's alias for the newest available Opus.

```text
review_inputs=$(mktemp -d) || exit 1
git diff --no-ext-diff <base>...HEAD > "$review_inputs/change.diff" || exit 1
# Export the applicable base files here as described above.
claude -p --model opus --restricted --strict-mcp-config --add-dir "$REVIEW_SKILL_DIR" "$review_inputs" -- "Follow the review skill at $REVIEW_SKILL_DIR/SKILL.md (and its references directory) to review the change whose diff is at $review_inputs/change.diff (base <base>, head <head>) in this checkout. Base inputs in $review_inputs: <base inputs>. Use the caller-verified exports as base evidence and identify them as supplied by the caller. Read-only, no network, no scanners, no closeout. Write no review record and run no bounded re-review. Your final message is the review report." > <report> 2> <report>.stderr.log
```

Keep the `--` before the prompt: without it, `--add-dir` takes the prompt as one more
directory argument, and the review never starts.

- `--restricted` removes the command-running tools, ignores the user, project
  and local settings files (so the branch's `.claude/settings.json`, hooks,
  plugins and commands stay out, and so do the user-scope skills), and confines
  the file tools to the working directory plus `--add-dir`; `--strict-mcp-config`
  skips the branch's MCP servers. The review skill is therefore handed over as a
  file: `--add-dir` makes its directory readable and the prompt names it. The
  checkout's `CLAUDE.md` still loads, as `AGENTS.md` does for `codex`: the
  trusted-checkout boundary above applies unchanged.
- The same mode, tree, fingerprint and report rules as for `codex exec review`
  apply; for one commit or uncommitted work, write that diff to the file and
  say so in the prompt.
- The measured first half was an Opus agent following the review skill on a
  frozen diff and the measured second half was `codex exec` with Sol at high
  effort; a live `claude -p` and the session's own model are the production
  proxies and were not measured.
- Skip it, and say so, with no `claude` on PATH or for a PR that is not
  checked out.

---

## Combining two sources

The general closeout pairing remains distinct from opt-in external security
scans in `../SKILL.md` §8. Only when that policy selects a scanner, use
[scanner commands](security-scanners.md) and return its report or failure.
A closeout requirement does not itself require external security scanners.

- A source that examined a **different state** than the pinned target is **excluded**, not
  merged in. Note the exclusion.
- Agreement between sources raises **confidence and prominence only** — never severity,
  never the verdict.
- A finding that no source confirmed against the pinned target may be reported as
  unconfirmed, but must not on its own produce a blocking verdict.
- A pass that returns nothing, or returns generic boilerplate with no engagement with the
  actual code, is **failed coverage**. Disclose it as such; it is not a clean bill for
  whatever it was meant to cover.
- Do not nest reviewers or repeat an equivalent completed pass. Reuse evidence
  only when tree/revision, base, scope, source, and findings disposition match.
  Partial output is incomplete coverage, not a completed review. Retry only for
  changed inputs, a transient failure, or an unresolved required coverage gap.

---

## The bounded re-review

`SKILL.md` §7 runs two independent re-reviews at the same time in a Claude
session after the findings so far are complete: this skill's own pass plus
the second model's verified findings. Measured on frozen PR heads, one
re-review of the files the first passes flagged found about 44% more known
defects at about 1.4× the wall time, with no more false findings on clean
controls. The cost counts the first passes' wall time and the re-review
agent's duration; the outer review's verification of the returned findings
was not timed.

**Operating point.** Two Agents with the newest available Opus (the runtime's
`opus` alias) at effort `medium`, the measured point, started in one message so
that they run at the same time. Both get the same brief; neither gets the other's
findings. Effort `high` gained only a little more at a much higher cost, and a
smaller model at effort `high` cost as much and added false findings.

**Why two runs.** Two runs of one brief find different defects: on held-out PR
heads they shared about half of their new key items. A second run adds about a
tenth more known defects over one run, for about 44% more Claude tokens and
about one minute when both start together. Its added findings are mostly true:
expect about three minor findings for every two wanted ones. A third run added
almost nothing and is not used.

**The brief.** Hand the agent:

- its role: the second pass of a two-pass review;
- the first pass's report and its findings (path, line, severity, summary);
- the instruction "assume the first pass missed half";
- the review skill at its installed path to follow, with §7's second-model
  pass, its bounded re-review and its record excluded, and §8 and §9
  excluded: the agent reviews alone (the measured agent followed a skill copy
  whose §7 had none of the three);
- the target (checkout, base, head, diff command) and the files the findings
  name: concentrate there and on the code that calls into them;
- report only defects the first pass did not contain;
- read-only: no edits, no network, no `gh`; write no review record;
- return findings with path, line, severity, confidence, summary and
  consequence, suspected ones included.

**What the outer review does with the result.** Verify each returned finding
against the cited code, as with the second model's findings: keep confirmed
ones, keep unverifiable ones as suspected, drop refuted ones and name them in
the discarded items. Where both runs report one root cause (the same
mechanism at the same place, so that one fix resolves both), keep one
finding. Its source is `rereview-1`, the run whose Agent call stands first in
the message, and its confidence is what your own verification gives. The
other copy goes nowhere: it is not a discarded item, and the record does not
show that both runs found the finding. A root cause that both runs report
and your verification refutes is different: each run's refuted finding is
its own `discarded` entry, so that the record counts every run's false
findings. Agreement between the two runs does
not raise confidence or prominence, unlike agreement between sources in
"Combining two sources": the runs are two draws of one brief, and no
measurement says that a finding both report is more often valid. Merge the
survivors into the report, each with a class as for every other finding. The
report does not say which run found a finding: a reader, human or agent,
would take such a label for a rank that nothing measured supports. The
record names the run of each finding it keeps. Run one round only: do not
re-review the re-reviews' findings.

**When to skip.** Skip it, and say so in the report, when the review so far
reported nothing (the measured first pass always had findings, so this case
is unmeasured), in a Codex session (no mirror of it was measured), and inside
the mirror's `claude -p`, which is a Claude session with the Agent tool and
whose prompt says so (the mirror is the first half of a Codex session's
review, where no re-review was measured). An
Agent that fails, times out or returns no report is a coverage gap of that
run, not a clean result: name it in the report and in the record's
`coverage.gaps`, as for any failed pass. The other run's result stands, and
the verdict follows `SKILL.md` §4 and §6 as for every coverage gap. A completed
report with no new defects is a valid result.

**The record.** The re-review's agents write no record. The outer review adds
one `sources` entry of kind `bounded-re-review` per run (ids such as
`rereview-1` and `rereview-2`), each with status `completed`, `failed`,
`timed-out` or `skipped` and a reason where the status is not `completed`. A
run's findings carry its source's id, and its discarded items join the
record's `discarded` list. A re-review that does not run at all (one of the
skip cases above) gets one entry, with id `rereview`, status `skipped` and
the reason; not one per run.

---

## The review record

`SKILL.md` §7 requires one record per review run. Write it as JSON with schema
version `review-record/1`. The record repeats the report's facts in fixed
fields; it does not replace the report.

- **Writing it.** Keep the record's JSON in a file in the session
  scratchpad. Write the record with the helper, which validates it, chooses
  the location and writes the file:

  ```text
  python3 "$REVIEW_SKILL_DIR/scripts/write-review-record.py" --record <scratchpad>/<record>.json --slug <target slug> --fallback-dir <scratchpad> --checkout <checkout>
  ```

  The slug holds lowercase letters and digits, with single hyphens between
  them, such as `guest-queue-214`. On success the helper prints only the
  written path; name that path in the report. On a non-zero exit it leaves
  no record file, except the partial file that a failed write under exit
  `5` names when the helper could not remove it. An empty `.reviews/` that
  the helper created can remain after exit `3` or `5`.
  - `1`: the record is invalid: it fails validation, is not JSON, holds NaN,
    Infinity or an unpaired surrogate escape such as `"\ud800"`, its
    `created_at` has digits that are not ASCII, or a finding's `fixed_in` is
    not an ancestor of `head_sha` or is an ancestor of `base_sha` in
    `--checkout` (`git merge-base --is-ancestor`; `--print-only` does not
    check it). Fix each error that is a mistake in the record and run it
    again. Never change a fact to make the
    record pass (`SKILL.md` §7).
  - `2`: a usage error, a bad slug, an unreadable record, or a
    `--checkout`, `--location` or `--fallback-dir` that is not an existing
    directory.
  - `3`: permission denied, for example by a command sandbox, which usually
    blocks the main worktree. Rerun the same command outside the sandbox.
    Never copy the record to another place by hand.
  - `4`: an entry that is not a symbolic link exists at the record path;
    the helper leaves it unchanged. Never delete or overwrite an earlier
    record.
  - `5`: the destination is unsafe (a symbolic link at `.reviews` or at the
    record path, or a `.reviews` of another account or one that group or
    others can write), `.reviews` or the record file could not be created
    or opened, or the write failed. Say so in the report.

  The helper validates with `validate_record.py` and `record.schema.json`
  beside it.

- **Location.** The helper applies this rule. A location the caller names
  takes precedence: pass it as `--location <dir>`. A caller names one only for
  a record that is not kept, such as an eval case or a read-only checkout,
  because a record in a scratchpad is gone before the next retro reads
  `.reviews/`. Otherwise the helper writes
  `<main worktree>/.reviews/<UTC yyyymmddThhmmssZ>-<target slug>.review.json`,
  with the time from `created_at`, where `<main worktree>` is the first
  `worktree` path that `git worktree list --porcelain` prints (a linked
  worktree's own `.reviews/` is deleted with it), only when both hold:
  `git check-ignore -q .reviews/<record name>` in the current checkout
  confirms that the record path (not only the directory: a rule such as
  `.reviews/*.json` ignores the file alone) is ignored, and the main
  worktree's root `.gitignore` is byte-identical to the current checkout's
  (a root `.gitignore` that is absent in both counts as identical; absent in
  one only counts as different).
  Each worktree checks out its own `.gitignore`, so the comparison stands in
  for a check in the main worktree; the shared `info/exclude` needs no
  comparison. When either check fails, or the first entry is marked `bare`
  (no main worktree exists), the helper writes the record to
  `--fallback-dir` and prints the reason on stderr; say so in the report.
  Never write a record inside a checkout that the caller marked read-only,
  such as an eval case: use the caller's location or the scratchpad. Never
  commit it. A read-only request forbids every write, not only writes inside
  the checkout: unless the caller named a location, run the helper with
  `--record - --print-only` and the JSON on stdin, and put the fenced `json`
  block that it prints at the end of the report, with `report_path` `null`.
  Do the same when no location is writable. Pipe the JSON in, because a
  worktree-isolated Claude session's command guard can refuse a heredoc:

  ```text
  printf '%s' '<json>' | python3 "$REVIEW_SKILL_DIR/scripts/write-review-record.py" --record - --print-only
  ```

- **Early stops.** A run that stops after §1 pinned its target writes a
  record with what it established, a `coverage` gap for the rest, and verdict
  `incomplete` unless a confirmed P1 remains. A run that cannot pin its target
  writes no record and says so in the report: `base_sha` and `head_sha` take
  no `null`.
- **Nested runs.** A run inside `codex exec review` or the mirror's
  `claude -p` writes no record: the first runs in a read-only sandbox, the
  second has no command tools. The outer review writes one record that covers
  both passes, with one `sources` entry for each. The bounded re-review's
  agents write none either. The outer review adds one `sources` entry of kind
  `bounded-re-review` per run (status `completed`, `failed`, `timed-out` or
  `skipped`, with a reason where not `completed`), or one `skipped` entry
  where the re-review does not run at all; a run's findings carry its
  source's id, and its discarded items join the `discarded` list.
- **Fields.** Every field is present. Only these take `null`, where a value is
  unknown or does not apply: `tree_fingerprint`, `guide.commit`,
  `guide.reason`, `reviewer.model`, `reviewer.effort`, a source's
  `report_path` and `reason`, a finding's `causal_link`, a discarded item's
  `path` and `line`, both token counts, and `report_path`. Every other field
  always carries a value.
  - `schema_version`: `"review-record/1"`. `created_at`: UTC, ISO 8601 with `Z`.
  - `target`: `mode` (`branch`, `commit`, `uncommitted`), `repo`, `base_sha`
    and `head_sha` (full SHAs; in `branch` and `commit` mode `head_sha`
    differs from `base_sha`), `tree_fingerprint` (for `uncommitted`, a
    `sha256:` digest of the fingerprint inputs in "`codex exec review`" above;
    otherwise `null`), `files_changed`, `non_test_lines`, `scope` (the §1
    scope statement).
  - `guide`: `status` (`used`, `absent`, `unavailable`), `path`, `commit`
    (required for `used` and `absent`), `reason` (required for `unavailable`).
  - `reviewer`: `runtime` (`claude`, `codex`, `other`), `model`, `effort`, from
    the launch configuration only; never inferred.
  - `sources`: one entry per pass, exactly one of kind `self` (the own pass)
    and at most two of kind `bounded-re-review`: `id` (lowercase letters,
    digits and hyphens, such as `self` or `codex`), `kind` (`self`,
    `codex-exec-review`, `closeout-review`, `claude-mirror`, `scanner`,
    `bounded-re-review`), `status` (`completed`, `empty`, `failed`, `timed-out`,
    `skipped`, `excluded`), `report_path`, `reason` (required unless
    `completed`). Helper reviewer agents that this run starts for its own
    pass, such as Workflow review lenses with a verifier per finding, are
    part of the source `self`; a finding's `summary` may name the lens.
  - `findings`: every reported finding, in report order: `id` (`F1`, `F2`, …),
    `path` (repository-relative), `line` (the first line of the cited region),
    `file_level` (`true`, with `line` 1, for a file-scoped finding),
    `severity` (`P1` must fix before this ships, `P2` worth knowing, `P3`
    preference), `route` (`fix-before-merge`, `follow-up`, `handed-back`; a
    confirmed `P1` routes `fix-before-merge`),
    `confidence` (`confirmed`, `suspected`), `summary`, `consequence`,
    `causal_link` (`null` for a finding in changed code), `source` (the id of
    a `completed` source), `class` (the defect class: a catalogue slug or
    alias, or a new slug the report lists under "New classes"; a kebab-case
    slug that matches `^[a-z][a-z0-9]*(-[a-z0-9]+){1,6}$` and is not a bare
    area word; see [finding classes](finding-classes.md)). The schema accepts a finding
    without `class` because older records have none; write it on
    every finding. `fixed_in` (optional, never `null`): the full SHA of the
    commit, contained in `head_sha` and not in `base_sha`, that fixed this
    finding after the reviewed state; set it only after the fix was
    re-checked (`SKILL.md` §5). Without it the finding remains at
    `head_sha`.
  - `discarded`: the considered-and-discarded items, refuted second-model
    findings included: `id` (`D1`, …), `kind` (`cleared`, `refuted`,
    `unsettled`), `path`, `line` (an item with a `line` also has a `path`),
    `summary`, `reason`, `source` (never `null`: the id of the source whose
    finding a `refuted` item refutes, otherwise the pass that cleared or
    left the item unsettled, usually `self`).
  - `coverage`: `complete` (a completed source inspected every in-scope file)
    and `gaps` (each part not covered; empty only when complete). A test or
    program run still owed for code a completed source read is proof owed
    (`SKILL.md` §4), not a gap: record it as an `unsettled` discarded item.
    A review pass or a part of the code that no completed source read stays a
    gap.
  - `verdict`: `passes-clean` (no findings, complete coverage),
    `passes-with-findings` (no confirmed P1 without `fixed_in`, complete
    coverage), `does-not-pass` (a confirmed P1 without `fixed_in`, whatever
    the coverage), or `incomplete` (coverage not complete and no confirmed P1
    without `fixed_in`). It agrees with the findings (§4).
  - `metrics`: `started_at`, `ended_at`, `wall_s`, `tokens` (`input`,
    `output`), `tokens_source` (`runtime` or `unavailable`). When the runtime
    does not report token counts, write `null` and `unavailable`; never
    estimate them. Read `ended_at` from the clock when you write the record,
    never a projected time, and set `wall_s` to `ended_at` minus `started_at`.
  - `report_path`: the prose report file, or `null` when the report is only in
    the reply.
- **Content.** Summaries and reasons are short prose. A finding about a
  credential names the file, the line and the class (§6), never the value.
  Write each `report_path` repository-relative or as an absolute path outside
  any home directory: a path under a home directory names the operator's
  account. A sandbox temporary directory that flattens a home path, such as
  the macOS session scratchpad `/private/tmp/claude-<uid>/-Users-<name>-…`,
  names it too; write such a path as `<scratchpad>/<file>`.

---

## Where this sits in the shipping routine

At a batch boundary, after the repo's direct author checks pass, before pushing. What
comes after belongs to other skills and is not this job: replying to PR review comments
(`address-feedback`) and the pre-all-clear readiness probe (`babysit-pr`). Preserve that
gate — a clean review here is not an all-clear.
