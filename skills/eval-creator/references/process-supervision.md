# Supervised local process execution

Use this optional adapter when a local framework cannot stop its active CLI
providers within the agreed campaign limit. Promptfoo still owns case scheduling,
results, and export. One Python controller owns cancellation. The provider only
captures output and requests cancellation.

## Install and qualify

The controller uses `psutil` 7.2.2. The hashed requirements permit wheels for
macOS arm64, Linux x86_64, and Linux arm64. Wheel availability does not qualify
runtime or cancellation behavior on Linux arm64. Run the checks below on each
target platform before live use. This path requires Unix process semantics and
Python 3.10 or newer. Other platforms also need separate dependency
qualification. A missing or different psutil version stops execution before the
framework or model starts. The report renderer has no extra dependencies.

```sh
python3 -m venv /absolute/operator-path/eval-venv
/absolute/operator-path/eval-venv/bin/python -m pip install \
  --require-hashes --only-binary=:all: -r <skill-dir>/requirements.txt
```

Before live use, run the process tests with that interpreter and the provider
tests with its `bin` directory on `PATH`. Use harmless fixture commands, then
verify the real framework can export their results. Test a normal completion,
timeout, interruption, surviving child, and unavailable process inspection.
These checks do not prove model authentication or full workflow execution.

## Launch one campaign

For a time-limited run, choose a per-trial cap in the briefing. It starts when the registration shim
begins admission and includes its wait for acknowledgement. Framework startup
and earlier provider setup count against the shared campaign allowance.
The trial clock is monotonic. Its wall-clock start timestamp is report metadata.
Reserve at least two seconds for cleanup inside the shared
allowance. Use an empty private registry for each attempt. Keep its parent and
all result paths outside the subject's sandbox. Example with a 20-minute total,
30-second cleanup reserve, and an explicitly chosen 5-minute trial cap:

```sh
/absolute/operator-path/eval-venv/bin/python <skill-dir>/scripts/run_campaign.py \
  --seconds 1200 --cleanup-seconds 30 --trial-max-ms 300000 \
  --registry /absolute/operator-path/attempt-1/registry \
  -- <existing-framework-command-and-arguments>
```

When the user explicitly authorizes work without a time limit, use `--uncapped`
instead of `--seconds`, `--trial-max-ms`, or either absolute deadline option.
Set the provider manifest's `trialMaxMs` to JSON `null`. The controller and
provider must agree on this mode. Do not substitute a large numeric deadline.
Keep the approved case and trial count fixed. Uncapped time does not authorize
extra attempts, billing changes, or additional model calls.

```sh
/absolute/operator-path/eval-venv/bin/python <skill-dir>/scripts/run_campaign.py \
  --uncapped --cleanup-seconds 30 \
  --registry /absolute/operator-path/attempt-1/registry \
  -- <existing-framework-command-and-arguments>
```

Uncapped work has no campaign or trial timer. Receipts record null work deadlines
and `trial_max_ms`. `--cleanup-seconds` remains finite. It starts when work ends,
the operator interrupts, the provider aborts, or execution fails. A trial cleanup
failure stops the campaign and leaves cleanup unverified. The provider also
bounds its observation after the subject exits or requests cancellation. This
cleanup interval is not a work allowance. Preserve partial artifacts on failure.
If the cancellation write fails, the provider returns incomplete so the owner
can stop the registered process tree. If the launcher exits before registration,
no matching cleanup receipt can arrive. Return incomplete with unknown cleanup
and usage instead of waiting for that receipt.
Send SIGINT to the controller to cancel; it remains the sole signaling owner.
SIGKILL, loss of the controller, and unobserved descendants do not establish
cleanup. The existing process-identity and operating-system inspection limits
below still apply. Qualify uncapped completion, interruption, provider abort,
framework exit, and failed inspection before using this mode.

The controller reserves its campaign receipt before launching the framework.
An existing receipt or reservation refuses the attempt before work starts.
An existing registry must belong to the current user. It must allow owner
read, write, and directory search, with no group or other access. The controller
rejects invalid permissions instead of changing them. Use trusted parent directories. These checks do not establish
isolation from another process running as the same user or inspect filesystem ACLs.
Use a different parent directory for each attempt. The controller records
`deadline_utc_ms` and `deadline_monotonic` in
`campaign-receipt.json` beside the registry. For a bounded run, a retry on the same host must pass
both original values with `--deadline-utc-ms` and `--deadline-monotonic`, using
a new registry. Do not create a fresh allowance. Set the absolute deadline
before any earlier execution preflight too. Do not move a monotonic timestamp
to another host or across a reboot.

Exit 0 means the framework exited successfully and observed owned processes
ended. It does not mean the reviews passed their graders. Exit 124 means the
campaign deadline was reached; 130 means interruption; 2 means launch, tracking,
or cleanup was incomplete. Other framework failures retain their exit code.
Signal termination uses the shell convention `128 + signal number`.

## Connect the Codex provider

Use `examples/codex/codex-review-provider.cjs` as a Promptfoo custom provider.
Supply an absolute manifest path through `config.manifest`. Each test supplies
`vars.case_id` and `vars.input`. Use `prompts: ['{{input}}']`. Both the rendered
prompt and `vars.input` must exactly match that case's manifest `prompt`.
The provider records the bound input's SHA-256 in its receipt and result metadata.
Qualify rendering with the installed Promptfoo version. Version 0.123.1 removes
one final line feed from string variables before rendering. A frozen input with
that ending is therefore refused by this configuration. Choose compatible input
when creating the case, or qualify a configuration that preserves its bytes.
Do not trim an existing frozen input to bypass this check.
Disable framework caching for fresh trials and preserve the
native JSON export. Pin and qualify your installed CLI flags before use.
Promptfoo supplies a zero-based `repeatIndex`. The provider accepts non-negative
safe integers. It records `repeat_index` in its receipt and `repeatIndex` in
result metadata.
Repeat 0 keeps the case's artifact stem. Later repeats add a repeat suffix so
each attempt keeps separate evidence. Invalid repeat values fail before launch.
Each repeat also gets a fresh `.eval-tmp/repeat-N` directory inside its case
repository. The permission profile denies the scratch parent and grants access
only to the current repeat's directory. The snapshot must not track `.eval-tmp`
or any path below it. An existing current scratch directory
refuses the trial before launch. Reuse of a case repository therefore does not
grant access to earlier repeats' scratch files.
The provider checks scratch roots, but does not traverse prior repeats' contents,
including scratch under other case repositories. Subject-created links there do
not block a later case or repeat. Explicit operator evidence paths retain their
separate link checks.
The case repository must already exist as a directory. A missing or invalid
directory refuses the trial before the provider creates output or scratch files.

The manifest contains:

- `codexPath`, `nodePath`, `gitPath`, and optional `rgPath` and `pythonPath`:
  verified absolute executable paths. Use the real Python executable for
  `pythonPath`, rather than a launcher that needs additional tool discovery.
- `toolSha256`: optional SHA-256 map keyed by each configured executable field
  above. When supplied, it must include every configured tool and no other keys.
  The provider checks the file bytes before each invocation and before its first
  Git query. A missing, invalid, or changed tool refuses the invocation.
  Existing manifests without this map retain their operator-verified path contract.
- `skillEntry` and `runtimeRoot`: frozen review and focused test-audit skills.
- `model`, `effort`, `serviceTier`, and `trialMaxMs`: explicit execution settings.
  A null service tier adds no override; it does not request fast service.
  For bounded work, the controller cap cannot exceed `trialMaxMs`. The prompt states the controller's
  actual cap, including when it is shorter than the manifest allowance.
  Only explicit JSON `null` selects uncapped work; omitted or invalid values fail.
- `resultsDir`, `denyPaths`, and `runtimeReadPaths`: absolute operator output,
  hidden evidence, and narrowly verified runtime-library paths.
- `allowUnchangedGitlinks`: optional opt-in for unchanged submodule pointers.
  The default refuses gitlinks in the subject index.
- `cases`: entries with `id`, `artifactStem`, `repo`, `base`, `head`, and `prompt`.
  Use an opaque stem such as `case-a`. Keep expected answers out of the prompt
  and isolated repository. Case IDs stay in operator metadata.
  IDs must be unique and match `[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}` exactly.
  Artifact stems must also be unique and match `case-[a-z0-9]+` exactly.
  `base` and `head` must be full immutable commit IDs. `prompt` must be non-empty.

When `pythonPath` is set, its directory comes first in the process and shell
PATH, before the Git executable directory. The `python3` entry in that directory
must resolve to the selected interpreter. An absent or different entry refuses
the invocation. This setting adds no filesystem grant. Include the verified
interpreter and required libraries in the runtime
read paths. The provider sets `TMPDIR` to the current scratch directory and
`TMPPREFIX` to `<scratch>/zsh` in both environments. Zsh here-documents can then
use temporary files inside the permitted scratch directory. Qualify these
operations in the actual trial sandbox before running subjects.

Prepare each case as a self-contained Git snapshot with two neutral commits:
a root base and its direct subject child. Detach HEAD at the subject commit.
Keep only their reachable objects and no named refs. Do not include remotes,
reflogs, alternates, replacement refs, or other object stores.
Keep Git metadata limited to `HEAD`, `config`, `index`, optional `packed-refs`,
Git-named loose objects, and `pack-<object-id>.pack`, `.idx`, `.rev`, or `.bitmap`
files. Only the standard object directories and empty `refs`, `refs/heads`, and
`refs/tags` directories are allowed. Remove template hooks, descriptions, commit
message files, exclude files, and server-info caches while preparing the copy,
before freezing it.
The provider refuses extra metadata; it does not remove it.
The provider checks this structure and resolves both commits before reserving
artifacts. The index and tracked working files must be clean at the subject commit.
Untracked and ignored files are refused outside the generated `.eval-tmp` directory.
The index normally contains only ordinary files, executable files, and symbolic
links. With `allowUnchangedGitlinks: true`, the complete base and head gitlink
inventories must match. Each gitlink location must be absent or an empty
directory. Added, changed, or deleted gitlinks and populated locations are
refused. The provider records the retained gitlink paths and tells the reviewer that
their source contents are absent. Disclose that coverage limit. Unresolved
stages and flags that suppress change detection remain refused.
Keep the local Git configuration minimal. The supported keys and values are:

- `core.repositoryformatversion`: `0` or `1`.
- `extensions.objectformat`: `sha1` or `sha256`, matching the frozen commit IDs.
- `core.filemode`, `core.symlinks`, and `core.trustctime`: `true`.
- `core.bare`, `core.logallrefupdates`, `core.ignorestat`, and `core.fsmonitor`: `false`.
- `core.ignorecase` and `core.precomposeunicode`: `true` or `false`.
- `core.checkstat`: `default`.

These keys may be absent. Other keys, include directives, and values are refused.
This excludes filters, redirected worktrees, and settings that hide file changes.
The untracked-file inventory compares path names with case sensitivity, regardless
of the stored `core.ignorecase` value.
Git validation explicitly selects the case's Git directory and working directory.
Git's built-in text and encoding normalization still applies; this check does not
compare raw filesystem bytes with stored blobs. The provider refuses invalid or
oversized metadata instead of modifying the repository. Record the original source
revisions separately in operator evidence.
This check cannot determine whether permitted files reveal an answer. Inspect
both the approved tree contents and permitted Git metadata during case design.
It also removes pre-base history from
the review context, which must be disclosed as a fidelity limit.

Each case and its Git metadata must belong to the current user. Files and
directories must not permit group or other writes. Parent directories must be
trusted. The provider checks these properties within a bounded metadata walk
and uses the canonical repository path for later launch and scratch operations.
Owned symbolic links remain valid leaves; the check does not follow their targets.
Their targets remain subject to the permission profile and operator grant review.
Prior scratch contents remain excluded after their root passes the checks.
These checks do not inspect filesystem ACLs or prevent same-user changes.

Both frozen skill entry files must be readable regular files before launch:
`skillEntry` and `runtimeRoot/test-audit/SKILL.md`. Symlinked entries are refused.

The provider rejects an explicit read or write grant equal to or inside a hidden
path, the results directory, or another case's repository. It checks normalized
paths and existing symlink targets before launch. A broad read grant may contain
a more-specific denied path; that denial remains in the permission profile.
Keep runtime libraries and subject files separate from hidden evidence.
Every explicit `denyPaths` entry and every case repository must exist.
Only generated results and scratch destinations may be absent before setup.
Hidden files must be independent copies. The provider rejects regular files with
multiple hard links and symlinks inside hidden directory trees. A configured
hidden root is resolved to its canonical path before the check. The provider
refuses launch if the metadata check cannot finish within its limits.
The check does not prevent a trusted operator from changing files after validation.

The results directory must belong to the current user with mode `0700`.
The provider refuses a symlink at that path and unsafe parent directories before
reserving artifacts. It keeps the canonical path for later writes. These checks
do not establish isolation from same-user changes or inspect filesystem ACLs.

This example uses ChatGPT subscription authentication. Its environment does not
forward API keys. It does not authorize API billing or external disclosure.
It implements the user-approved **code-inspection** scope from the review pilot:
external security scans and the separate repository closeout review are omitted.
Use that scope only when explicitly approved for the current eval. Change and
qualify the adapter before claiming complete `/review` workflow coverage.

## How the safeguards work

The controller binds its framework root through the retained `Popen` child.
It checks child liveness around identity capture and verifies the process parent
before adopting that identity. Failed initial binding leaves descendant cleanup
unverified and never grants ownership of a replacement PID.

The provider starts `registered_exec.py`, which records its own PID and OS
creation time. Each launch also has a unique registration ID. Registration,
acknowledgement, cancellation, and cleanup files use that ID, so a reused PID
does not collide with an earlier trial's evidence. The controller accepts the
exact process identity only after observing
it as a descendant of the framework. The shim waits for a matching acknowledgement
before it replaces itself with Codex. Replacement preserves the process identity.
The subject receives no supervisor registry variables.
Registration reads refuse links and non-regular files before decoding bounded
JSON. Invalid field types enter the normal tracking-error cleanup path.
The controller exports work and hard monotonic deadlines. The provider samples
the same Python monotonic clock once and maps the remaining allowances to its
own monotonic clock. It includes the probe time conservatively. UTC timestamps
remain metadata; wall-clock changes do not reset admission or observation limits.
The controller polls the framework immediately before acknowledging the trial
and refuses acknowledgement if it has exited or cancellation is pending.
The controller and shim inspect cancellation markers without following links.
A regular file requests cancellation. Any other occupied marker path is invalid
and stops admission or execution, including a dangling symlink.
The shim checks cancellation again before starting Codex. These checks and process
replacement are not atomic. Framework exit or cancellation can still occur after
the final check; later cancellation follows the normal controller cleanup path.

A shim can exit after cancellation or its admission deadline before the controller
first observes it. The controller isolates this case only when the registration is
valid, a fresh snapshot has no such PID, no acknowledgement exists, and that PID has
no previously observed owned generation. A regular cancellation marker must be
present or the valid
trial deadline must have expired. Its receipt records `pre_admission_cancelled: true`
and `execution_started: false`. The reason is `provider_abort` when cancellation is
present, otherwise `trial_deadline`. Cleanup remains unverified. This incomplete
trial does not cancel unrelated trials.

The controller retains `psutil.Process` objects for observed identities. It
retires exited or replaced processes and continues tracking their known children.
It never adopts a replacement merely because it has an old PID. It checks each
identity again before signaling. Cancellation escalates from interrupt to terminate
to kill within the remaining cleanup allowance. The provider sends no signals.
If a successful inspection or registration finishes after the hard deadline,
the controller makes one final identity-checked kill attempt for remaining owned
processes. It adds no wait. Cleanup stays unverified until exit is observed.
This does not bound operating-system inspection calls. The late direct-child
fallback still runs without a fresh snapshot; that gap remains open.

A failed process snapshot cannot authorize descendant signals. The controller
retries inspection up to three consecutive failures, then stops its direct
framework child through the retained `subprocess.Popen` handle. This handle
belongs to the child it launched; it does not depend on the failed process-table
snapshot. The same fallback applies if initial identity capture fails.
The controller records descendant cleanup as unverified and preserves the error
and affected identity where known. Unknown ownership is not evidence that a
process ended. Missing or mismatched registration prevents
the model from starting; missing cleanup evidence prevents a successful trial.

## Read the evidence and its limits

Preserve `campaign-receipt.json`, registry registrations and acknowledgements,
per-trial cleanup receipts, native JSONL, stderr, final output, and the provider
receipt. Failed trials keep their partial files. Existing output files are
never silently overwritten. The provider reports missing token counts as unknown.
An output-pipe read error requests cancellation and produces an incomplete result.
A short or failed JSONL or stderr write also requests cancellation. The provider
marks the saved trace incomplete and leaves token counts unknown.
Final cleanup receipts retain the trial's cancellation reason when the campaign
also stops. Pending provider cancellation and an expired trial deadline take
priority when the controller first records a trial reason. The campaign reason
does not replace that more specific evidence.
If a final trial receipt cannot be published, the controller records that error
and continues with the other receipts and campaign report. It does not replace a
conflicting file. A campaign report publication failure is reported on stderr and
leaves the reservation marker in place. Receipt finalization failures return exit 2.

The cleanup field is `owned_processes_gone`. It covers the observed process
identities. Update a saved-output grader explicitly to consume this field;
do not synthesize the old `group_gone` field. Every receipt also records
`unobserved_descendants_verified: false`. Polling cannot prove that it saw a
child which detached and lost its parent before observation. Keep subprocess
work in the foreground. Use an OS containment boundary if that stronger guarantee
is required. The PID check and signal are separate system calls, not an atomic
kernel process handle.

The old local runner aborted when a historical group leader's PID changed. Its
receipt omitted that PID, so the exact event cannot be reconstructed. Deterministic
controls reproduced the stale-identity failure and unsafe stale-snapshot behavior.
This implementation fixes those reproduced paths; it does not turn the failed
model run into quality evidence.

See the [psutil process contract](https://psutil.io/7.2/#psutil.Process) and
[Python monotonic clock contract](https://docs.python.org/3/library/time.html#time.monotonic).
