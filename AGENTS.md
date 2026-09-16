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
`scripts/check-shell-size.sh` enforces the limits and CI runs it on every
pull request.

Limits:

- A `.sh` file holds at most 500 lines.
- A function holds at most 60 lines. A long here document or JSON snippet
  belongs in `assets/` or a separate file, not inside a function.
- A test file covers one topic of one subject. A subject written in
  JavaScript is tested from JavaScript with `node:test`, never from a bash
  harness.

Layout for a script that outgrows one file:

```text
scripts/<tool>.sh              entry point: option parsing, sources lib/, calls main
scripts/lib/<tool>/<topic>.sh  one topic per file; defines functions, runs nothing at load
scripts/test-<tool>.sh         runner: sources tests/lib/, runs every tests/<tool>/*.sh
scripts/tests/lib/<name>.sh    shared assertions, fixtures, and shims
scripts/tests/<tool>/<topic>.sh cases for one topic, in the same order as lib/
```

Rules for a module file:

- It is sourced, never executed: no shebang, no `set -e`, no code outside
  function bodies except constants.
- The entry point resolves its own directory with `pwd -P` and sources every
  module by absolute path, so the installed hook and a symlinked clone both
  work.
- Each module names, in a comment at the top, the globals it reads and
  writes. A module that needs a variable another module owns takes it as a
  function argument instead where that is practical.
- `.shellcheckrc` sets `source-path`, so `shellcheck scripts/*.sh` follows
  the `source` lines. Do not add `# shellcheck disable=SC1091`.

Two files predate these limits and are listed in
`scripts/shell-size-baseline.txt` with their current line count:
`scripts/link-skills.sh` and `scripts/test-link-skills.sh`. A change may not
grow either of them. Add a case or a function by first splitting the topic it
belongs to out of the monolith, then lower the baseline entry to the new
count: the check fails while the entry is above the file's real length, so
the allowance only ratchets down. Remove the entry once the file fits the
limit; the check refuses an entry at or below 500 lines.

Run the check locally before opening a pull request:

```bash
bash scripts/check-shell-size.sh
```
