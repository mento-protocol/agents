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

`.github/workflows/claude.yml` reviews a PR when it opens and when a draft
becomes ready, not on later pushes. That automatic review skips fork PRs and
bot-authored PRs. For a later review, or any other request, write `@claude`
in a PR or issue comment, a review, or a new issue. The workflow accepts
that from an organization owner or member, the action then requires write
access, and the workflow refuses a request on a fork PR. The workflow needs
the `CLAUDE_CODE_OAUTH_TOKEN` secret.

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
`/bin/bash` on macOS) and pass `shellcheck` clean. The entry point sources its
topic modules from `scripts/lib/link-skills/` by absolute path from an explicit
ordered list, so it needs that directory next to it; the harness copies the
script and the directory into every fixture through
`fixtures_install_script`. That directory also holds `merge-hook.py`, the
program `install-hooks.sh` runs with `python3` to merge the SessionStart hook
into a settings file. It is data to the shell, not a module: nothing sources
it and it carries no execute bit.

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
`link-skills.sh`. Four `LINK_SKILLS_TEST_*` variables shorten those waits for
the harness alone, and none of them acts in normal use:

- `LINK_SKILLS_TEST_LOCK_WAIT_SECONDS`: the seconds a run waits for a lock
  another run holds. The harness sets 2 for every case, in place of 10.
- `LINK_SKILLS_TEST_HOOK_DEADLINE_SECONDS`: the wall-clock budget of the
  session hook. The two deadline cases set 3, in place of 25.
- `LINK_SKILLS_TEST_LOCK_PAUSE_SECONDS`: how long a run holds the lock it took
  before it starts work. One case sets it; there is no default pause.
- `LINK_SKILLS_TEST_FETCH_TIMEOUT_SECONDS`: the bash-native timeout of a
  `git fetch`. The case for a fetch that hangs sets 3, in place of 15.

Each takes 1 to 999 seconds, and any other value keeps the default. Nothing
under test is skipped by them: the retry loop, the stale-lock clearing, the
refusal, the deadline, the TERM then KILL sequence and the exit codes all run
as they do in normal use.

## Shell scripts

Bash gets the same modularity rules as JavaScript. A script is a set of
small files with one topic each, not one file that holds everything.
`scripts/check-shell-size.mjs` enforces the limits and CI runs it on every
pull request. It reads function boundaries with the shfmt parser
(`mvdan-sh`, pinned to the exact version `0.10.1`), so they follow bash
grammar, and a file the parser rejects fails the check. The checker is
maintained here and copied byte-identical into other repositories, so it
holds no constant of this repository.

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
scripts/lib/<tool>/<name>.<ext> a program in another language a module runs; never sourced
scripts/test-<tool>.sh         runner: sources tests/lib/, runs each tests/<tool>/<topic>.sh from an explicit ordered list
scripts/tests/lib/<name>.sh    shared assertions, fixtures, and shims
scripts/tests/<tool>/<topic>.sh cases for one topic, in the same order as lib/
scripts/tests/<tool>/<topic>.test.mjs  node:test cases for a JavaScript subject, one topic per file
scripts/tests/<tool>/helpers/<name>.mjs shared fixtures and builders for those cases
```

The tests for `scripts/validate-skills.mjs` live under
`scripts/tests/validate-skills/`: one file per YAML topic, plus
`cli.test.mjs` and `layout.test.mjs` for the command's own behaviour, and a
`helpers/` directory with the shared fixtures and builders. The tests for
`scripts/check-shell-size.mjs` live under `scripts/tests/check-shell-size/`:
`limits.test.mjs`, `baseline-rows.test.mjs` and `ratchet.test.mjs`, plus a
`helpers/` directory whose fixture builds a throwaway git repository for each
case and runs the checker in it as a command. Run both directories with
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

`scripts/shell-size-baseline.txt`, beside the checker, holds the exemptions
in two kinds of row. A file row is `<path> <count>` and allows that file
`<count>` lines. A function row is `<path> <function> <count>` and allows the
longest declaration of that function `<count>` lines. Blank rows and rows
that start with `#` are skipped. A file row exempts the length of the file
only: its functions are checked at 50 lines like any other, and so is a
second declaration of an exempt function name. A nested function is measured
on its own and as part of the function that holds it, so both lengths have to
pass.

A row is an upper bound, not an exact count. The file or function may sit at
or below its count. Below it the run prints one advisory line and still
passes, so two changes that each shrink one exempt subject merge without
leaving `main` red. That line asks for the lower count, or for the row to go
away once the subject fits the ordinary limit. Above it the run fails. A count
at or below the limit is refused: remove the row instead.

On a pull request CI sets `SHELL_SIZE_BASE` to the base branch, and the
baseline may then only ratchet down. A row may fall, and a row may go away. A
row may not rise, and a row whose key the base's baseline lacks is refused, so
a removed row cannot return and a new exemption cannot be added. The baseline
file itself may not be removed. When the base lacks the baseline at the
current path, the checker looks for the file by name anywhere in the base
tree, so moving the checker and its baseline together keeps the comparison.
The ratchet is what closes the baseline, so the checker holds no list of the
files that may be exempt.

A function row is keyed by path and function name. Renaming an exempt
function, or moving it to another file, makes it a new function, which the
ratchet refuses. When an over-length file is split by topic, its exempt long
functions stay in the original file while the short functions move out, or
they are split as they move.

This repository's baseline holds no rows. Both legacy monoliths have been
split: `scripts/test-link-skills.sh` left the list once the runner held no
case, and `scripts/link-skills.sh` left it once its topics moved to
`scripts/lib/link-skills/`. Every `.sh` file is now checked at the full
limits. Keep the file with its header comment even though it holds no rows. A
script that outgrows a limit is split by topic; it does not get an exemption.

Run the check locally before opening a pull request, after `pnpm install`:

```bash
pnpm check:shell
```
