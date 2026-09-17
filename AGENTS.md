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
and layout. CI runs it on every pull request.

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
2. Run `node scripts/validate-skills.mjs` and fix every reported problem.
3. Verify the skill from a fresh clone: run `scripts/link-skills.sh`, then
   `scripts/link-skills.sh check`, and confirm the skill links with no
   drift.
4. Delete the source copy in the personal library in the same change, so
   the skill has only one home.
5. For a third-party skill, record its upstream source and license in the
   skill's `SKILL.md` frontmatter.
6. Keep `SKILL.md` under 500 lines and keep `references/` one level deep.

## Install path

`scripts/link-skills.sh` is the only supported way to install these skills
into `~/.agents/skills`. It must stay compatible with bash 3.2 (the default
`/bin/bash` on macOS) and pass `shellcheck` clean.

After changing it, run its harness, which CI runs on Ubuntu and macOS:

```bash
shellcheck scripts/*.sh
bash scripts/test-link-skills.sh
BASH_BIN=/bin/bash bash scripts/test-link-skills.sh  # macOS: the bash 3.2 pass
```

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
scripts/test-<tool>.sh         runner: sources tests/lib/, runs every tests/<tool>/*.sh
scripts/tests/lib/<name>.sh    shared assertions, fixtures, and shims
scripts/tests/<tool>/<topic>.sh cases for one topic, in the same order as lib/
scripts/tests/<tool>/<topic>.test.mjs  node:test cases for a JavaScript subject, one topic per file
scripts/tests/<tool>/helpers/<name>.mjs shared fixtures and builders for those cases
```

The parser tests for `scripts/validate-skills.mjs` live under
`scripts/tests/validate-skills/`: each file covers one YAML topic, and
`cli.test.mjs` runs the command itself over a temporary skills/ tree. Run
them with `pnpm test:scripts`.

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
- `.shellcheckrc` sets `source-path`, so `shellcheck scripts/*.sh` follows
  the `source` lines. Do not add `# shellcheck disable=SC1091`.

Two files predate these limits and are listed in
`scripts/shell-size-baseline.txt` with their current line count:
`scripts/link-skills.sh` and `scripts/test-link-skills.sh`. The check
refuses any other path in that file. A change may not grow either of them. Add a case or a function by first splitting the topic it
belongs to out of the monolith, then lower the baseline entry to the new
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
