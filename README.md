# agents

Mento Protocol tooling for automated and human-in-the-loop repository agents.
A pnpm workspace; each package under `packages/*` publishes independently to
npm as `@mento-protocol/<name>`.

## Packages

- [`packages/issues`](packages/issues/README.md) — `@mento-protocol/issues`.
  GitHub ref-backed claims (a compare-and-swap mutex with an opt-in lease), a
  bounded `gh` runner, and procedural-marker byte contracts. Ships the
  `mento-issues` CLI.

## Skills

`skills/*` holds agent skills shared across the team: reusable instructions
an AI coding agent loads for a specific kind of task. Each skill lives at
`skills/<name>/SKILL.md`.

Claude Code, Codex, and OpenClaw each read skills from the flat assembly
directory `~/.agents/skills`. `scripts/link-skills.sh` builds that directory
out of one or more source repositories by symlinking each skill into it.
Claude Code and Codex reach the assembly through the `~/.claude/skills` and
`~/.codex/skills` symlinks the script also creates; OpenClaw reads
`~/.agents/skills` directly.

### Install

Clone this repository anywhere, then run the link script:

```bash
git clone git@github.com:mento-protocol/agents.git
cd agents
scripts/link-skills.sh
```

If `~/.agents/skill-sources` does not exist yet, the script creates it with
one line pointing at this clone's `skills` directory. If the file already
exists, the script leaves it alone: add this clone's `skills` directory as a
line yourself, as shown under
[Composing with a personal skills directory](#composing-with-a-personal-skills-directory).
Either way it then links every skill from every source the file lists into
`~/.agents/skills`.

Every run names the sources it used (`link-skills: sources: ...`) and warns
when this clone's own `skills` directory is not one of them.

The script points `~/.claude/skills` and `~/.codex/skills` at the assembly
only when `~/.claude` or `~/.codex` already exists; it creates neither home
directory and names the runtime it skipped. An existing real `~/.claude/skills`
that is empty is replaced by the symlink (a directory holding only Finder
metadata such as `.DS_Store` counts as empty), and one that holds anything else
is refused with a message telling you to move it aside.

### Update

```bash
git pull
scripts/link-skills.sh
```

`git pull` brings in new or changed skills; `link-skills.sh` (its default
subcommand is `link`) re-links the assembly directory to match.

One run at a time writes the assembly. `link` and `unlink` take the lock
directory `~/.agents/skills/.skill-links.lock`, wait up to 10 seconds for a run
already in progress, and then exit 1 having changed nothing; the session hook
skips its own update silently instead of waiting. The lock lives inside the
assembly directory, so every command that writes the assembly creates that
directory first: the very first run on a machine is locked like every other
one. A run holds the lock only when it created that directory itself: a lock
another run gives back while this one is waiting is taken, not read as
permission to go on without it. Each run gives its lock back when it ends, the
session hook included. A lock left behind by a run that was killed is removed
once its process is gone. A lock whose owner is still running is kept however
old it is, and a lock that records no owner at all is removed after two
minutes. A symlink or a file at the lock path is not a lock this script made:
`link` and `unlink` report it and exit 1 without reading or removing anything
below it, and the hook steps aside in silence.

The manifest `~/.agents/skills/.skill-links` is the only record of what the
script may remove later, so every command that reads it refuses a manifest path
that is a symlink or is not a regular file, and changes nothing. A manifest
that is there but cannot be read is refused the same way: `link`, `check` and
`unlink` report it and exit 1 before they change anything, and the hook steps
aside. A run is one transaction: if the manifest cannot be written, the links
that run created are removed again, the links it repointed carry their previous
target again, the links it pruned are created again at the target the manifest
still records, links it found already recorded stay, and the run exits 1. A
recorded link that now has to point somewhere else and that the script cannot
remove is reported, keeps the target it already had and its manifest entry,
and makes `link` exit 1: no new link is created for it.

`~/.agents/skill-sources` must be a regular file. Anything else at that path,
such as a directory or a named pipe, is refused with exit 2 before the script
opens it. A sources path that names one of the assembly's own control paths is
refused the same way, whatever spelling reaches it: the manifest, the lock
directory, the fetch stamp directory `.skill-links.d` and anything inside it,
and any entry in the assembly root whose name starts with `.skill-links`. A
run would otherwise read its own record as a list of sources, or write a
bootstrap sources file over it. The refusal comes before anything is read,
written or created.

### Status

```bash
scripts/link-skills.sh check
```

Reports drift in the assembly directory (missing, stale, collided, or foreign
links) and, for each git source, how many commits it is behind its
`origin`. It creates and removes no links. Entries the script did not create
are not reported by `check`; they are left alone. A link that points at a
skill directory other than the one the sources now produce is stale drift, and
counts as a problem: run `link` to repoint it. A recorded link whose target
directory still exists but no longer holds a `SKILL.md` is an orphan, and
counts as a problem too: the next `link` run prunes it.

`check` does reach the network: it runs `git fetch` for every git source every
time you run it, and records each fetch in a
`~/.agents/skills/.skill-links.d/fetch-*` stamp file. The 6-hour throttle
below applies to the session hook, not to `check`. A failed fetch is a note,
not an error. `check` exits 1 when it reports a problem, 0 when it does not,
and 2 when there is no sources file to work from.

### Session notice

```bash
scripts/link-skills.sh install-hooks
```

Adds a Claude Code and Codex `SessionStart` hook that runs
`link-skills.sh hook` and prints a one-line notice when a source clone is
behind. To let the hook fast-forward a clean clone on its default branch
automatically instead of only notifying, add `auto-update` after that
source's path in `~/.agents/skill-sources`. An `auto-update` source is left
alone when the update would overwrite a file the clone ignores: git replaces
an ignored file without a word, so the hook names the file and prints the
manual `git pull --ff-only` command instead.

A session hook runs with none of the environment the person who installed it
had, so `install-hooks` writes the paths of the installation it was run for
into the command: `--sources` and `--assembly` are added when `--sources`,
`--assembly`, `SKILL_SOURCES_FILE` or `SKILLS_ASSEMBLY_DIR` set a path that
differs from the default for the `HOME` in effect. An installation on the
default paths keeps the plain `bash <script> hook` command. A rerun of
`install-hooks` for the same installation recognises either form and reports
the hook as already installed. A rerun for another installation, with other
`--sources` or `--assembly` paths, rewrites the stored command to the new
paths instead of keeping the old one. Every command the hook prints for you to
run carries the same options, so the advice names the installation it reported
on.

The hook fetches each source at most every 6 hours (override with
`SKILL_SOURCES_FETCH_INTERVAL_HOURS`, `0` to fetch every time) and stops
fetching once it has spent 20 seconds, so a notice can lag a teammate's push
by that interval. Run `scripts/link-skills.sh check` to force a fresh look:
that throttle is the hook's alone.

The hook never blocks a session start. Its whole run, including fetches, the
merge, any local git hook the merge runs, and the scan afterwards, is bounded
by 25 seconds of wall clock: past that it stops the work it started, prints
`hook timed out after 25s`, and exits 0. A path it cannot use, such as an
unset `HOME` or a manifest that is not a regular file, is one line and exit 0
too. The other commands keep exit 2 for the same refusal.

`install-hooks` edits `~/.claude/settings.json` and `~/.codex/hooks.json`,
creating either file when it is missing, and copies the previous content of an
existing file to `<file>.bak-<UTC timestamp>` before it changes anything. It
reports each runtime as installed once the hook is added and as already
installed once the hook is already there, and exits 0 once every reachable
runtime is in one of those states. A file that already runs the hook is left
byte for byte as it is: it is neither reformatted nor backed up. A hook entry
whose script file name is exactly `link-skills.sh` and whose path no longer
exists is dead, so it is repointed at this script instead of being kept, and
the run reports that it replaced a stale hook. An entry whose script path is
relative, such as `bash scripts/link-skills.sh hook`, is dead in the same way:
a session start runs from the directory of the project it opens, where that
path names another file or none, so it is repointed too. An entry whose script
file is there but whose `--sources` or `--assembly` names another installation
runs an assembly this run is not for, so it is rewritten to the current
command and the run reports that it replaced a hook for another installation;
an omitted option is read as the default for the `HOME` in effect, and the two
paths are compared after symlinks are resolved. An entry that runs a
different script, such as `custom-link-skills.sh hook`, is another tool's, so
it is kept as it is and this hook is added beside it. A file it creates itself gets mode
`0600` and no backup. A backup name already in use
gets a `.1`, `.2` suffix, so no earlier backup is overwritten. A runtime whose
home directory does not exist yet is skipped and named in the output. The JSON
merge needs `python3`; without it the command prints the group to add by hand
and exits 1.

### Composing with a personal skills directory

`~/.agents/skill-sources` holds one source directory per line, so a
personal skills library can compose with this repository. Each line names
the directory whose immediate children are skill directories holding a
`SKILL.md`, not the repository root above it. Add a second line pointing at
your own:

```text
~/code/agents/skills
~/code/my-skills/skills
```

A line that points one level too high links nothing; the script warns when a
listed source holds no skill.

A source directory the script cannot read says nothing about what belongs in
the assembly, and neither does a skill directory inside a readable source that
the script cannot read. Both keep their recorded links and their manifest
entries, both are reported by path, and `link` and `check` exit 1. When a name
whose skill directory could not be read is also provided by another source, the
two copies are a duplicate this run cannot resolve: the recorded link and its
manifest entry stay as they are, the name is not repointed at the readable
copy, and `link` reports both sources and exits 1. A skill directory that reads
fine and no longer holds a `SKILL.md` is a skill that was removed, so its link
is pruned.

Skill names must be unique across every source. `link-skills.sh` refuses
to link a name that collides between sources, keeps whichever link already
worked, and it never touches an assembly entry it did not create itself. A
skill directory placed directly in `~/.agents/skills` is one such foreign
entry: the script leaves it alone instead of adopting it. The supported way to
add such a skill is to list its parent directory as a source.

### Remove

```bash
scripts/link-skills.sh unlink
```

Removes the skill links this script recorded, and the manifest. Everything
else in `~/.agents/skills` stays untouched, including the `~/.claude/skills`
and `~/.codex/skills` symlinks: remove those by hand if you are uninstalling
completely, before you delete `~/.agents/skills`.

A link `unlink` cannot remove is reported, keeps its manifest entry so a later
run still recognises it, and makes the command exit 1.

## Development

```bash
pnpm install
pnpm test                        # pnpm -r test — every package's test suite
pnpm validate:skills             # node scripts/validate-skills.mjs
bash scripts/test-link-skills.sh # the link-skills.sh harness
trunk check --all                # lint (or: pnpm lint)
trunk fmt                        # format (or: pnpm format)
```

CI runs the last two skill checks on Ubuntu and macOS. On macOS also run
`BASH_BIN=/bin/bash bash scripts/test-link-skills.sh`, which exercises the
bash 3.2 that `link-skills.sh` must keep working with.

Each package's own README documents its usage; run its suite directly with
`pnpm --filter <package-name> test` during development.

## Publishing a package

Publishing is two steps, matching this repository's trusted-publishing setup:

1. **First release only (operator, manual).** From the merged `main`, an
   operator with a 2FA-backed npm account runs
   `npm publish --workspace packages/<name> --access public`, then enables
   [npm trusted publishing](https://docs.npmjs.com/trusted-publishers) for the
   package on npmjs.com, pointing at this repository
   (`mento-protocol/agents`) and `.github/workflows/publish.yml`. This is a
   precondition for any consumer that depends on the published version.
2. **Every release (including the first, redundantly).** Push a tag shaped
   `<package-name>@<version>` — today only `@mento-protocol/issues@*`, which is
   the one tag pattern `.github/workflows/publish.yml` triggers on — once the
   version bump is on `main`. A second package needs its own trigger pattern
   and its own filtered test and publish steps in that workflow.

   The workflow checks out with `persist-credentials: false`, installs with
   `pnpm install --frozen-lockfile`, installs `npm@11.5.1` globally (trusted
   publishing needs a recent npm), **verifies the tag matches `package.json`,
   then runs the package's test suite**, and finally publishes via npm trusted
   publishing (OIDC — no `NODE_AUTH_TOKEN`, and provenance is generated
   automatically). It skips publishing without failing when the exact version
   already exists on the registry, so the operator's manual first publish and
   the tag-triggered workflow never conflict.

No package here declares runtime `dependencies`. A consumer that cannot add a
workspace dependency runs a package's CLI through `dlx`, naming the binary
after `dlx` and the pinned spec through `--package`:

```bash
pnpm --config.ignore-scripts=true --package=@mento-protocol/issues@0.1.0 \
  dlx mento-issues <command> [...args]
```

The shorter `pnpm dlx <spec> <binary>` form does not work: pnpm passes the
binary name to the CLI as its first positional argument.
