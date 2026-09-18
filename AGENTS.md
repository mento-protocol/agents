# Repository rules

## Purpose

This repository is a pnpm workspace with two kinds of content:

- `packages/*` — npm packages published as `@mento-protocol/<name>`. See the
  root `README.md` for the publishing process.
- `skills/*` — shared agent skills. Any coding agent that reads the assembly
  directory `~/.agents/skills` can use them. See the "Skills" section of the
  root `README.md` for how a skill reaches that directory.

## Skills layout

Each skill lives at `skills/<name>/SKILL.md`, where `<name>` equals the
directory name. A skill directory may also contain:

- `agents/openai.yaml`: an adapter for a runtime that needs skill metadata
  in a different format.
- `scripts/`: helper scripts the skill runs.
- `references/`: supporting documents the skill reads on demand.
- `assets/`: files the skill's output is built from or copies.
- `fixtures/`: recorded inputs and byte vectors the skill's own test suite
  under `scripts/` reads.
- One archived companion document next to `SKILL.md`, such as
  `SEALED-LEGACY.md`, when a superseded procedure must stay readable.

Run `node scripts/validate-skills.mjs` to check every skill's frontmatter
and layout, and `node --test skills/*/scripts/*.test.mjs` to run every
skill's own suite; on a host whose temp directory is world-writable, set
`DEPENDABOT_PREP_TEST_SEALED_ROOT` to a directory only you can write. CI runs
both on every pull request.

## Public readership

This repository is public. Do not commit:

- Internal hostnames or private repository names.
- A real person's machine paths (for example `/Users/<name>/...`) or home
  directory contents.
- Incident notes or postmortems tied to a specific person or machine.
- Model-routing rules that are personal preference rather than a fact about
  the skill's own behavior.

Use generic examples instead, for example `~/code/agents` or
`~/code/my-skills`.

## Pull request rule

Make every tracked change on a branch and open a pull request. Do not push
directly to `main`. A PR needs a green CI run before it is ready. Do not
merge, or enable auto-merge, without the explicit approval of whoever
requested the change, given for that specific PR.

## Promoting a skill from a personal library

Follow this checklist when moving a skill from a personal skills library
into this repository:

1. Scrub the skill for the public-readership rule above: internal
   hostnames, private repository names, personal machine paths, incident
   notes, and personal model-routing rules.
2. Run `node scripts/validate-skills.mjs` and
   `node --test skills/*/scripts/*.test.mjs`, and fix every reported problem.
3. Verify the skill from a fresh clone: run `scripts/link-skills.sh`, then
   `scripts/link-skills.sh check`, and confirm the skill links with no
   drift.
4. Delete the source copy in the personal library, so the skill has only one
   home. Merge the company-side addition and pull it on every consumer first;
   the personal-side removal merges after. `link-skills.sh` prunes a dangling
   link on its next run, so any gap uninstalls the skill everywhere
   (dependabot-prep, 2026-09-17).
5. For a third-party skill, record its upstream source and license in the
   skill's `SKILL.md` frontmatter.
6. Keep `SKILL.md` under 500 lines and keep `references/` one level deep.

## Install path

`scripts/link-skills.sh` is the only supported way to install these skills
into `~/.agents/skills`. It must stay compatible with bash 3.2 (the default
`/bin/bash` on macOS) and pass `shellcheck` clean.

After changing it, or after changing any file of its harness, run the harness,
which CI runs on Ubuntu and macOS:

```bash
git ls-files -z '*.sh' | xargs -0 shellcheck
bash scripts/test-link-skills.sh
BASH_BIN=/bin/bash bash scripts/test-link-skills.sh  # macOS: the bash 3.2 pass
```

The harness is `scripts/test-link-skills.sh`, which holds no case of its own.
It sources six modules from `scripts/tests/lib/` (`case.sh`, `assert.sh`,
`fs.sh`, `fixtures.sh`, `shims.sh`, `probe.sh`) and then one file per topic
from `scripts/tests/link-skills/`, each by absolute path from an explicit
ordered list. `scripts/tests/link-skills/install-hooks-common.sh` holds no
case either: it carries the settings-file builders more than one install-hooks
topic calls, so the list sources it before every install-hooks topic that calls
them. `BASH_BIN` sets the interpreter the script under test runs under; it
defaults to `bash`.

The harness reports in TAP 13: a `TAP version 13` line, a `# interpreter:`
comment naming the interpreter and its version, one `ok` or `not ok` line per
case, the detail of a failure as `#` comment lines, a `1..N` plan, and a last
comment line with the passed, failed and skipped counts and the interpreter. A
case whose capability is missing on this machine, such as `python3`, calls
`case_skip` and is reported as `ok N - name # SKIP reason`, which is a verdict
of its own and never a pass.

The harness runs four cases at a time. Every case has a subshell, a `HOME` and
a case directory of its own, so the cases do not reach each other, and the TAP
lines still come out in registration order. `HARNESS_JOBS` sets the number of
workers, and `HARNESS_JOBS=1` runs one case at a time:

```bash
HARNESS_JOBS=1 bash scripts/test-link-skills.sh
```

Most of what a run waits for is a lock or a deadline inside
`link-skills.sh`. Three `LINK_SKILLS_TEST_*` variables shorten those waits for
the harness alone, and none of them acts in normal use:

- `LINK_SKILLS_TEST_LOCK_WAIT_SECONDS`: the seconds a run waits for a lock
  another run holds. The harness sets 2 for every case, in place of 10.
- `LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS`: the wall-clock budget of the
  session hook. The two deadline cases set 3, in place of 25.
- `LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS`: how long a run holds the lock it took
  before it starts work. One case sets it; there is no default pause.

Each takes 1 to 999 seconds, and any other value keeps the default. Nothing
under test is skipped by them: the retry loop, the stale-lock clearing, the
refusal, the deadline, the TERM then KILL sequence and the exit codes all run
as they do in normal use.

## Shell scripts

Bash gets the same modularity rules as JavaScript. A script is a set of
small files with one topic each, not one file that holds everything.
`scripts/check-shell-size.mjs` enforces the limits and CI runs it on every
pull request. It reads function boundaries with the shfmt parser
(`mvdan-sh`), so they follow bash grammar, and a file the parser rejects
fails the check.

Limits:

- A `.sh` file holds at most 500 lines.
- A function holds at most 50 lines, the ESLint default for JavaScript. A
  long here document or JSON snippet belongs in `assets/` or a separate
  file, not inside a function.
- A test file covers one topic of one subject. A bash harness may drive a
  program written in another language as a black box, through its command
  line. Tests of that program's internals, such as how a JavaScript module
  parses one YAML construct, belong next to the module in `node:test`.

Layout for a script that outgrows one file:

```text
scripts/<tool>.sh              entry point: option parsing, sources lib/, calls main
scripts/lib/<tool>/<topic>.sh  one topic per file; defines functions, runs nothing at load
scripts/test-<tool>.sh         runner: sources tests/lib/, runs each tests/<tool>/<topic>.sh from an explicit ordered list
scripts/tests/lib/<name>.sh    shared assertions, fixtures, and shims
scripts/tests/<tool>/<topic>.sh cases for one topic, in the same order as lib/
scripts/tests/<tool>/<topic>.test.mjs  node:test cases for a JavaScript subject, one topic per file
scripts/tests/<tool>/helpers/<name>.mjs shared fixtures and builders for those cases
```

The tests for `scripts/validate-skills.mjs` live under
`scripts/tests/validate-skills/`: one file per YAML topic, plus
`cli.test.mjs` and `layout.test.mjs` for the command's own behaviour, and a
`helpers/` directory with the shared fixtures and builders. Run them with
`pnpm test:scripts`. The cases of `scripts/test-link-skills.sh` live under
`scripts/tests/link-skills/`, one file per topic, sourced from an explicit
ordered list the way the modules are; the runner itself holds no case. Each
topic file ends with a `cases_<topic>` function that calls `case_run` for its
cases in order, and the runner's `main` calls those functions in order. A
helper file shared by several topics, such as `install-hooks-common.sh`, holds
no case and so has no `cases_<topic>` function; it is sourced before the topics
that call it. A helper used by one topic file alone stays in that file and
starts with `_`.

Rules for a module file:

- It is sourced, never executed: no shebang, no `set -e`, no code outside
  function bodies except constants.
- The entry point resolves its own directory with `pwd -P` and sources each
  module by absolute path from an explicit list in a fixed order, the way
  Kubernetes `hack/lib/init.sh` and `sdkman-init.sh` do. Do not source by
  glob: glob order depends on the locale and hides which module needs which.
- A module's public functions carry the module name as a prefix, for
  example `lock_take`; helpers private to the module start with `_`.
- Each module names, in a comment at the top, the globals it reads and
  writes. A module that needs a variable another module owns takes it as a
  function argument instead where that is practical.
- `.shellcheckrc` sets `source-path`, so
  `git ls-files -z '*.sh' | xargs -0 shellcheck` follows the `source` lines.
  Do not add `# shellcheck disable=SC1091`.
- A `shellcheck disable` directive sits on the line it excuses, not at the
  top of the file, and carries a comment saying who needs it. A global one
  module writes and another reads takes
  `# shellcheck disable=SC2034 # read by <module>` on that assignment. A
  file-level directive silences the rest of the file as well, including code
  written later.

`scripts/link-skills.sh` predates these limits and is listed in
`scripts/shell-size-baseline.txt` with its current line count. It is the only
entry left, and the only path the baseline may name:
`scripts/test-link-skills.sh` was listed too, and its entry went once the
runner held no case and fit both limits, so the runner is checked like any
other file now. The check refuses any other path, and the ratchet refuses the
runner's entry if it returns. A change may not grow a listed file. Add a case or a function by first splitting the topic
it belongs to out of the monolith, then lower the baseline entry to the new
count: the check fails while the entry is above the file's real length, and
on a pull request CI also compares the change with the base branch, so
the allowance only ratchets down: an entry may not rise, a removed entry
may not return, the baseline file itself may not be removed, and a
function over 50 lines in a legacy file passes only when the base branch
already has that function at that length or longer. Remove an entry once
its file fits the limit; the check refuses an entry at or below 500 lines.
Keep the baseline file even once it holds no entries.

Run the check locally before opening a pull request, after `pnpm install`:

```bash
pnpm check:shell
```
