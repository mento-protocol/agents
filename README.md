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

When that existing `~/.claude/skills` holds skills you want to keep, move it
to a new home and list that home as a second source, so the assembly holds
your skills and the shared ones side by side:

```bash
mv ~/.claude/skills ~/my-skills
scripts/link-skills.sh
echo ~/my-skills >> ~/.agents/skill-sources
scripts/link-skills.sh
```

The first run creates `~/.agents/skill-sources` and points `~/.claude/skills`
at the assembly; the second links your skills into it. If the sources file
already existed, the first run leaves it alone, so add this clone's `skills`
directory to it as well before the second run, or the shared skills are not
linked. From then on edit your
skills in `~/my-skills`, never through `~/.claude/skills`, which is now a
symlink into the assembly. See
[Composing with a personal skills directory](#composing-with-a-personal-skills-directory)
for the format of the sources file.

Because those two paths become links into the assembly, the assembly directory
must not be either of them and must not hold either of them. An `--assembly`
or `SKILLS_ASSEMBLY_DIR` path that is, or contains, `~/.claude/skills` or
`~/.codex/skills` is refused with exit 2 before anything is created, since the
link would point into itself and every reader that walked below it would walk
forever. The comparison uses the resolved paths, so an alias spelling is
refused too. The session hook reports the same refusal in one line and exits 0.

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
writes no link, so it takes no lock and reports whatever it finds. The lock
lives inside the assembly directory, so every command that writes the
assembly creates that directory first: the very first run on a machine is
locked like every other one. A run holds the lock only when it created that
directory itself: a lock another run gives back while this one is waiting is
taken, not read as permission to go on without it. Each run gives its lock
back when it ends. A lock left behind by a run that was killed is removed
once its process is gone. A lock whose owner is still running is kept however
old it is, and a lock that records no owner at all, or an incomplete record,
is removed after two minutes. A symlink or a file at the lock path is not a
lock this script made: `link` and `unlink` report it and exit 1 without
reading or removing anything below it. The hook never looks at the lock path.

The manifest `~/.agents/skills/.skill-links` holds one line per link, with
three tab-separated columns: the skill name, the target it points at, and the
source directory the link came from, spelled as the sources file spells it
once the path is absolute, before any symlink or `..` in it is resolved.
That third column is what keeps the links of a source whose symlink
alias has disappeared: nothing in the target names the alias, so without it a
source that is listed and merely missing would look like a source nobody
lists. A two-column line written by an older version is still read, and the
next run rewrites it with three columns.

The manifest is the only record of what the
script may remove later, so every command that reads it refuses a manifest path
that is a symlink or is not a regular file, and changes nothing. A manifest
that is there but cannot be read is refused the same way: `link`, `check` and
`unlink` report it and exit 1 before they change anything, and the hook steps
aside. A run is one transaction: if the manifest cannot be written, the links
that run created are removed again, the links it repointed carry their previous
target again, the links it pruned are created again at the target the manifest
still records, links it found already recorded stay, and the run exits 1. The
session hook has nothing to roll back: it creates and removes no link and
writes no manifest. A recorded link that now has to point somewhere else and
that the script cannot
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
`origin`. A branch that tracks nothing is measured against the default branch
of `origin`, taken from `refs/remotes/origin/HEAD`, or, when that optional ref
is missing, from `origin/main`, `origin/master`, or the only remote branch
there is; when none of those settle it, `check` reports `behind unknown` and
prints `default branch unknown; run: git remote set-head origin --auto`. It
creates and removes no links. Entries the script did not create are not
reported by `check`; they are left alone. A link that points at a
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
`link-skills.sh hook`. The hook only notifies. It fetches each git source
under the throttle below, then prints one line for each source clone that is
behind, naming the clone, its branch, whether its work tree is clean or dirty,
and the command that updates it:
`cd <clone> && git pull --ff-only && <script> link`. A branch that tracks
nothing is measured against `origin/<default branch>`, and a bare pull there
only reports that there is no tracking information, so the command names them:
`git pull --ff-only origin <default branch>`. It prints one more line
when the assembly has drifted from the sources: how many skills are not
linked, and how many links are stale, each with the `link` command that fixes
them, and one more when a skill's name is taken by an entry this script did
not create, with the `check` command that names the entry. A manifest path
that is not a regular file is the one thing it reports instead of drift: a
`link` run would refuse that path, so the hook prints that one line and stops
counting. It never changes a
clone, never creates or removes a link, and takes no lock, so a `link` or
`unlink` run in progress neither blocks it nor is disturbed by it. The only
thing it writes is the fetch stamp below.

A sources line is one path, spaces in the path included. The one token refused
is a trailing `auto-update`: an older sources file could put it after a path,
and the hook then fast-forwarded that clone, so the token states an
expectation this script no longer meets. Every command refuses that line.
`link`, `check`, `unlink` and `install-hooks` exit 2; the hook says the same
thing in one line and exits 0. `auto-update` is refused whether or not the
path before it is there.

Every other line is the path as it is written, so a word after a directory is
part of the path and not a token: nothing in the format can tell a stray word
from a path that holds a space. A line that names no directory is reported as
a missing source, which is what a source that has been renamed or is
temporarily away already is: `link` and `check` exit 1, and the line links
again the moment the directory is back. A path is resolved the way the kernel
resolves it, symlinks first and then `..`, so `/a/alias/../skills` with `alias`
pointing at `/b/child` names `/b/skills` and not `/a/skills`. While `alias` is
away that line names no directory at all and is reported as a missing source;
a `..` after a name that is not there never falls back to the collapsed text,
so the run does not switch to `/a/skills` and does not prune the links it
recorded under `/b/skills`.

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

The hook never blocks a session start. Its whole run, including the fetches,
the behind counts and the scan afterwards, is bounded by 25 seconds of wall
clock: past that it stops the work it started, prints
`hook timed out after 25s`, and exits 0. A path it cannot use, such as an
unset `HOME`, is one line and exit 0 too. The other commands keep exit 2 for
the same refusal.

`install-hooks` edits `~/.claude/settings.json` and `~/.codex/hooks.json`,
creating either file when it is missing, and copies the previous content of an
existing file to `<file>.bak-<UTC timestamp>` before it changes anything. It
reports each runtime as installed once the hook is added and as already
installed once the hook is already there, and exits 0 once every reachable
runtime is in one of those states. A file whose entry already matches this
installation whole, in its command, its `type` and its `timeout`, is left byte
for byte as it is: it is neither reformatted nor backed up. An entry that
carries the right command under another `type` or another `timeout` runs the
hook under a budget this script never installed, or does not run it at all, so
its `type` and `timeout` are rewritten, the file is backed up, and the run
reports that it normalized the hook entry. A hook entry
whose script file name is exactly `link-skills.sh` and whose path no longer
exists is dead, so it is repointed at this script instead of being kept, and
the run reports that it replaced a stale hook. An entry whose script path is
relative, such as `bash scripts/link-skills.sh hook`, is dead in the same way:
a session start runs from the directory of the project it opens, where that
path names another file or none, so it is repointed too. An entry that runs the
script through an interpreter other than `bash`, such as `sh
/path/link-skills.sh hook`, is dead in the same way: `/bin/sh` is `dash` on
many systems and the script fails there at its first bashism, at every session
start, so it is repointed and the run reports that it replaced a hook that ran
the script through that interpreter. A bare `bash` is resolved on `PATH` at
every session start, so it counts as this hook; `bash` spelled as an absolute
path counts only while that path holds an executable file, and an entry such as
`/removed/bin/bash /path/link-skills.sh hook` is dead, so it is repointed and
the run reports that it replaced a hook whose interpreter is gone. A command
that runs the script directly with no interpreter at all counts as this hook
only while that file carries its executable bit; without it the kernel refuses
the file at every session start, so the entry is dead and is repointed like a
stale one. An entry whose script
file is there but whose `--sources` or `--assembly` names another installation
runs an assembly this run is not for, so it is rewritten to the current
command and the run reports that it replaced a hook for another installation;
an omitted option is read as the default for the `HOME` in effect, and the two
paths are compared after symlinks are resolved. The tokens after the script are
read the way the script itself reads them, so an entry such as
`bash <script> --sources hook` does not run the hook at all: the word is the
option operand, the subcommand falls back to `link`, and a session start would
write a sources file named `hook`. That entry, and any other shape this script
would refuse, is rewritten to the current command and the run reports that it
replaced a malformed hook command. Only one entry holds this hook: when the
hook is already installed, every other entry this script owns, whether it is
an exact duplicate or one of the broken shapes above, is removed from the file
instead of left running beside the good one, and the run reports how many
duplicate hook entries it removed. Every entry taken over this way
is rewritten whole: its type becomes `command`, its command the current one,
and its timeout the one this script installs, so an entry written by hand or by
an older version cannot leave the hook running under another budget. An entry
that runs a
different script, such as `custom-link-skills.sh hook`, is another tool's, so
it is kept as it is and this hook is added beside it. A file it creates itself gets mode
`0600` and no backup. A backup name already in use
gets a `.1`, `.2` suffix, so no earlier backup is overwritten. The name is
reserved, by creating the file, before the copy runs, so two runs inside the
same second never choose the same one. A settings file that another process or
an editor changes while the command runs is left alone, and the command asks to
be run again. A runtime whose
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
entries, both are reported by path, and `link` and `check` exit 1. A skill
directory that reads fine and holds a `SKILL.md` the script cannot open is
treated the same way: the runtime would reach a file it cannot read, so the
name is reported, a recorded link and its manifest entry are kept, a skill
nothing records yet is not linked, and `link` and `check` exit 1. When a name
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
pnpm test:scripts                # node:test cases for scripts/validate-skills.mjs
pnpm validate:skills             # node scripts/validate-skills.mjs
pnpm check:shell                 # .sh file and function size limits
node --test skills/*/scripts/*.test.mjs  # every skill's own suite; see below
bash scripts/test-link-skills.sh # the link-skills.sh harness, 4 cases at once
trunk check --all                # lint (or: pnpm lint)
trunk fmt                        # format (or: pnpm format)
```

The dependabot-prep push suite refuses a scratch root or a Node binary on a path
with a group- or world-writable component. Where `/tmp` or the Node install is
such a path, do what CI does: create a mode-0700 directory, copy `node` into a
`bin/` below it, set `DEPENDABOT_PREP_TEST_SEALED_ROOT` to that directory, and
run the suites with the copied `node`.

CI runs `shellcheck`, `pnpm validate:skills`, `pnpm test:scripts`, the skill
suites and the harness on Ubuntu and macOS, and the package tests,
`pnpm check:shell` and trunk on Ubuntu. On macOS also run
`BASH_BIN=/bin/bash bash scripts/test-link-skills.sh`, which exercises the
bash 3.2 that `link-skills.sh` must keep working with. `HARNESS_JOBS` sets how
many cases the harness runs at a time, four by default;
`HARNESS_JOBS=1 bash scripts/test-link-skills.sh` runs them one after another.

The harness prints TAP 13 and ends with a
`# N passed, N failed, N skipped (interpreter <name>)` line. It is
`scripts/test-link-skills.sh`, a runner that holds no case: it sources six
modules from `scripts/tests/lib/` and one file per topic from
`scripts/tests/link-skills/`, where the shared `install-hooks-common.sh` comes
before the install-hooks topics that call it. The cases for
`scripts/validate-skills.mjs` are
`node:test` files under `scripts/tests/validate-skills/`.

`scripts/link-skills.sh` is an entry point as well: it sources its topic
modules from `scripts/lib/link-skills/` by absolute path from an explicit
ordered list, so a copy of the script needs that directory beside it. The
harness copies both into every fixture.

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
pnpm --config.ignore-scripts=true --package=@mento-protocol/issues@0.2.0 \
  dlx mento-issues <command> [...args]
```

The shorter `pnpm dlx <spec> <binary>` form does not work: pnpm passes the
binary name to the CLI as its first positional argument.
