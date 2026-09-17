# Dependabot preparation: preparation

Paths such as `scripts/` and `fixtures/` are relative to the skill root,
not this reference directory or the candidate repository. Resolve them from
the loaded skill location. Numbered sections refer to the shared workflow.

## 5. Use a sanitized no-exec preparation clone

A linked Git worktree is forbidden because it shares writable Git metadata and
configuration with the controller repository. Use a separate clone made from a
sealed bundle of the authenticated head and exact base. The clone must have its
own Git common directory and no remote.

### Credentialed GitHub control

The runtime may query GitHub and fetch exact refs. With the corresponding
explicit grant, it may push one admitted commit, request a configured review,
post a required top-level comment, post replies, or rerun one proven
infrastructure failure. The model and credential remain
technically capable of any broader action that the token permits. The hard
limits are procedural unless a separately reviewed write proxy enforces them.

Do not execute a program, hook, package-manager command, test, build, generator,
plugin, local binary, or helper from the candidate head in this domain.

### No-exec preparation clone

Create the sealed bundle with synthetic exact head and base refs. Record its
digest and give the clone no remote URL or persisted credential. Create it from
the bundle with `clone --no-checkout`. Inspect the complete tree before the
first checkout. Keep the model project root and working directory in the
pre-model launch context. Reach the clone only through the current-host-tested
absolute-path access mechanisms. Use only a trusted Git binary with:

- an empty inherited environment and an explicit allowlist containing only a
  trusted absolute `PATH`, the new temporary `HOME`, XDG and temporary
  directories, a fixed locale, and the required sanitized Git controls;
- `GIT_CONFIG_NOSYSTEM=1`, `GIT_NO_REPLACE_OBJECTS=1`, and an empty global Git
  configuration;
- `GIT_TERMINAL_PROMPT=0` for every Git call;
- an empty template directory and a trusted empty hooks directory;
- disabled signing, credential helpers, aliases, external diff tools, text
  conversion, filters, and custom merge drivers; and
- a fixed trusted commit message and explicit author identity.

Do not carry `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_*`, `GIT_CONFIG_VALUE_*`,
`GIT_CONFIG_PARAMETERS`, `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`,
`GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`,
`GIT_NAMESPACE`, `GIT_REPLACE_REF_BASE`, `GIT_TERMINAL_PROMPT`,
`GIT_PAGER`, `PAGER`, `GIT_EDITOR`, `GIT_SEQUENCE_EDITOR`, `GIT_MERGE_AUTOEDIT`,
`EDITOR`, `VISUAL`, `GIT_ASKPASS`, `SSH_ASKPASS`, `GIT_SSH`,
`GIT_SSH_COMMAND`, `GIT_EXTERNAL_DIFF`, or `GIT_DIFF_OPTS` into the Git
environment. Do not carry `SSH_AUTH_SOCK`. Rebuild the same allowlisted
environment for every Git call, including bundle creation. Set
`GIT_NO_REPLACE_OBJECTS=1` and `GIT_TERMINAL_PROMPT=0` explicitly for each
call. Do not add a remote after the clone.

Do not set the runtime command tool's cwd to the candidate clone. Do not open an
interactive shell or PTY there. The reviewed command adapter must spawn the
trusted Git binary directly with an argv array and sanitized environment, then
set the Git child cwd to the exact clone root without shell startup. If the
runtime instead uses Git's `-C`, the command process must start in the trusted
launch context and the current-host test must prove the exact non-shell argument
path. Native read and edit tools may touch candidate paths only when the same
test proves they do not start formatters, editors, language servers, watchers,
hooks, autoenv, or network activity. Otherwise use a reviewed data-only adapter
or keep the run read-only.

### One-shot push credential boundary

This package includes `scripts/credential-helper.mjs`,
`scripts/credential-push-exact-cas.mjs`, and their deterministic boundary
tests. Install both as operator-owned regular files
outside every checkout and candidate path. Pin their canonical resolved paths
and reviewed SHA-256 digests in operator configuration. Install the helper as an
executable. Bind a trusted absolute
`node` through the sanitized `PATH`; the helper uses `/usr/bin/env node` only
through that path. A link, candidate-writable path, missing executable bit,
digest mismatch, or untested host keeps branch writes disabled.

The helper implements the Git credential-helper protocol and accepts only one
operation argument from Git. For `get`, it reads one size-bounded credential
record from standard input. It requires the exact `protocol=https`, canonical
host, and `path=<owner>/<repository>.git` bound by trusted live repository
evidence. It rejects duplicate, malformed, contradictory, or oversized fields.
For `store` or `erase`, it drains one bounded record, emits nothing, changes no
state, and returns. It rejects every other operation.

For `get`, the adapter may obtain the token only from a protected runtime secret
channel, such as a pre-opened private file descriptor or an approved host
credential provider. It must not read the candidate worktree, repository
configuration, or unrelated user state. It writes only the credential-protocol
username and password fields to the private helper-to-Git standard-output pipe.
It writes no credential to standard error. A `store` or `erase` input can
contain the credential returned by Git. Treat that input as secret. Drain and
discard it without parsing the password into state. Do not capture, tee, log, or
expose either private pipe to the model. The adapter must not place the token in
a URL, command argument, process title, log, file, model-visible value, or
environment.

Set these helper inputs only from authenticated operator configuration. Require
each path to be its exact canonical real path:

- `DEPENDABOT_PREP_CANDIDATE_ROOT`: the standalone clone root. Run the push with
  this exact current working directory.
- `DEPENDABOT_PREP_GIT_HOST`, `DEPENDABOT_PREP_GIT_OWNER`, and
  `DEPENDABOT_PREP_GIT_REPOSITORY`: the canonical live repository tuple.
- `DEPENDABOT_PREP_EXPECTED_LOGIN`: the authenticated operator login from the
  live GitHub identity query.
- `DEPENDABOT_PREP_NODE_PATH`: the exact canonical reviewed Node executable.
  The helper requires `realpath(process.execPath)` to equal this value.
- `DEPENDABOT_PREP_GH_PATH`: the fixed absolute executable path of the reviewed
  GitHub CLI provider.
- `DEPENDABOT_PREP_GH_SHA256`: the reviewed lowercase SHA-256 digest of that
  exact provider executable.
- `DEPENDABOT_PREP_GH_CONFIG_DIR`: the protected provider configuration
  directory outside the candidate root.

The bundled helper rejects a different current directory and rejects itself,
the provider, or the provider configuration at or below the candidate root. It
invokes only `<gh-path> auth token --hostname <host> --user <login>` in the
protected configuration directory with a separate allowlisted environment. It
does not pass the caller environment to the provider.

Before enabling branch writes, trusted non-model launcher code must call only
`pushExactCas` from the installed `scripts/credential-push-exact-cas.mjs` for
the branch write. Pin that module and
`scripts/credential-helper-toolchain.mjs` and
`scripts/credential-helper-git-config.mjs` by canonical path and reviewed
SHA-256 digest. The one-shot wrapper must receive and verify exact pins for all
three loaded modules. Pass the canonical reviewed Git, Node, and GitHub CLI executable
paths and the reviewed lowercase 64-hex toolchain-manifest digest through
protected operator configuration. Missing production pins keep write mode
disabled. The manifest binds the Git, Node, and GitHub CLI executables and
versions, every canonical executable path component, Git's reported and resolved
exec path, `/bin/sh`, `/usr/bin/env`, the host platform, architecture, and
release, and these exec-path programs: `git`, `git-index-pack`,
`git-unpack-objects`, `git-pack-objects`, `git-send-pack`,
`git-receive-pack`, `git-remote-http`, and `git-remote-https`. A missing module,
invalid pin, manifest mismatch, path drift, executable drift, version drift, or
host drift keeps branch writes disabled. The model must not select or update
these inputs. Every bound executable and path component must be model-unwritable.
Otherwise, record that the process inventory is not a technical boundary and
keep branch writes disabled until an outer control closes that residual.

The one-shot wrapper must validate the exact candidate root, local configuration
digest, old and new OIDs, destination ref, repository tuple, fast-forward
ancestry, sealed helper, empty trusted directories, and complete production
pins without credentials. It must then repeat the complete toolchain and helper
verification and directly spawn one exact Git push. Control must not return to
the model between that final verification and the push. It must never retry a
failed, timed-out, signalled, rejected, or ambiguous push. Re-read live state
before a later attempt.

The launcher must prevent concurrent model commands and other same-UID writers
for the complete wrapper lifetime. The POSIX owner and mode component check is
necessary evidence. It does not prove model-write isolation when the model and
the operator share a UID. Keep branch writes disabled unless a runtime-enforced
control also denies model writes to every pinned executable, module,
configuration path, and candidate Git metadata path for that lifetime.

Enable the adapter only for the exact compare-and-swap push in step 12. Reset
all inherited helpers. Git executes helper strings through a shell. Trusted,
reviewed non-model code must encode the canonical helper path as one POSIX
single-quoted shell word. It must reject NUL, CR, and LF. The reviewed JavaScript
implementation is `const word = "'" + path.replaceAll("'", "'\"'\"'") + "'"`
followed by `const helper = "!exec " + word`. The model must not generate,
interpolate, or evaluate this string. Pass that exact value as the second
command-local credential-helper entry after an empty reset entry. Set
command-local `credential.useHttpPath=true`.
Set command-local `http.followRedirects=false`.
Use the exact canonical HTTPS destination
`https://<host>/<owner>/<repository>.git`. It must contain no user information,
query, fragment, or unverified redirect. Do not add this URL as a remote. Do not
use `gh auth setup-git`. Keep `GIT_TERMINAL_PROMPT=0`; a missing credential must
fail without a fallback prompt. Close the secret channel, erase in-memory token
state, and make the adapter unavailable immediately after the push attempt.
Rebuild the normal credential-free allowlisted environment for the next Git
call. Block the branch write when this adapter is unavailable or its boundary
has not passed its current host tests. Run
`node --test scripts/credential-helper.test.mjs` from the reviewed skill package
with no real credential in the test environment. Require all tests to pass.
Also run `node --test scripts/credential-push-exact-cas.test.mjs` and
`node --test scripts/write-boundary-contract.test.mjs`. Then run the bundled
no-secret Git credential integration probe with the
installed executable, fixed Git and Node paths, a hostile metacharacter-bearing
helper path, a fake provider, and the exact production `!exec` encoding. Require
the `fill`, `approve`, and `reject` operation sequence and no injection marker.
Bind the result to the helper, provider, Git, Node, host, and operating-system
identities. The current-host probe must also pass no-network
`git-remote-https`, `git-index-pack`, and `git-unpack-objects` probes; the exact
file-descriptor-only `fill`, `approve`, and `reject` trace; and a controlled
local compare-and-swap push with the exact expected-OID lease. Reject an
unexpected executable, child process, shell transition, or Git plumbing path.
This local probe does not trace a live HTTPS push. Record that residual. Do not
claim live HTTPS process confinement unless a reviewed HTTPS fixture or an
outer process tracer observes and admits the complete live executable set.

On a POSIX host where the default temporary directory has group or other write
permissions, create an empty operator-owned scratch directory with mode `0700`.
Set `DEPENDABOT_PREP_TEST_SEALED_ROOT` to its exact canonical path for the
exact-CAS test. The test verifies every path component before it uses the
directory. Do not weaken the production path check or change the permissions of
the system temporary directory.

Before checkout, use non-executing Git object reads to reject gitlinks,
symlinks, malformed paths, path traversal, case-folding collisions, and any
tree mode other than an ordinary file or directory. Reassert those checks on
the final tree. Treat executable-bit files as data and never run them.

The agent may inspect and edit ordinary files as data with the runtime's
structured read and patch tools. It may run the trusted Git operations required
to inspect, merge, stage, and commit. It must not run a repository command or
load candidate configuration as executable code. If a merge requests a custom
driver, filter, hook, or external program, stop. If a required repair needs
lockfile generation, code generation, formatting, or another candidate
command, use the optional execution path or classify the PR as `manual`.

Trusted base policy may permit exact-head CI to replace local candidate
execution. In that case, record that local commands were not run. Push the
no-exec commit, then require all policy-selected secretless CI checks to pass on
that exact head before `prepared for maintainer decision`. A zero-check or
partially reported CI set is not validation.

### Optional local execution

Local candidate execution requires all of these:

- the invocation has the `execute` grant;
- trusted base policy permits the exact command;
- a reviewed isolation adapter passes its boundary tests on the current host;
- the adapter receives no GitHub, registry, cloud, signing, deployment, SSH,
  keychain, CLI, or unrelated credential;
- the candidate cannot read or write the controller, user state, sockets, or
  unrelated paths;
- network is disabled except for exact base-approved public registry hosts
  during a scripts-disabled fetch phase; and
- tests, generators, lifecycle scripts, builds, and commit run with no network.

Different shell invocations, a temporary `HOME`, or unset token variables do
not establish this boundary. If no tested adapter exists, do not execute
candidate code. Continue with the no-exec CI path only when base policy permits
it. Otherwise report `manual` or `blocked`.

Use a frozen or immutable install when the adapter path is available. Use the
manager's documented equivalent of `npm ci`,
`pnpm install --frozen-lockfile`, version-appropriate Yarn immutable mode, or
`bun install --frozen-lockfile` for an inspectable text lockfile. Do not expose
a private-registry token.

## 6. Prepare one PR in a standalone clone

Repeat this section independently for each admitted PR.

1. Query the complete live identity, lineage, feedback, history, rules, checks,
   and auto-merge state. Fetch the exact live head and base. Recheck the
   `branch` grant and `autoMergeRequest: null`.
2. Bind policy and validation requirements to the exact base OID. Create and
   digest the sealed input bundle. Do not include a remote URL or credential.
3. Create a unique standalone clone with `--no-checkout`. Confirm its separate
   Git common directory, allowlisted environment, sanitized configuration,
   absent remotes, and `HEAD == headRefOid`. Inspect all tree modes and paths.
   Only then check out the admitted ordinary files and confirm a clean state.
4. If the base is not an ancestor, prepare one merge of the exact `baseRefOid`
   with no-commit and no-fast-forward behavior through the trusted sanitized
   Git path. Do not let Git create a clean merge commit before inspection.
   Never rebase. Resolve only conflicts caused by the PR and its base. Stop if
   Git requests executable behavior.
5. Inspect the manifest and lockfile delta. Confirm the requested target,
   update type, peer constraints, workspace coverage, override changes, and any
   protected-runtime coupling.
6. Apply only required conflict fixes, proven coupled updates, and valid review
   fixes. Do not update unrelated dependencies to reduce lockfile noise.
7. Select validation from trusted base policy. Use the tested adapter only with
   the `execute` grant. Otherwise use the permitted CI-only path. Classify the
   PR as `manual` when a required edit or proof needs unavailable execution.
8. Inspect the complete diff and dependency delta with non-executing tools.
   Reject unexpected package, version, integrity, registry, generated-file,
   workflow, deployment, credential, symlink, gitlink, or path changes. When
   base policy forbids workflow or local-Action ref mutation, require zero such
   paths in the candidate delta from the authenticated old head.
9. Reassert the no-exec clone controls. Accept exactly one of these outcomes:
   create one unsigned two-parent merge commit whose parents are the prior head
   and exact base; create one unsigned one-parent repair commit when the exact
   base was already an ancestor; or create no commit when the current native
   head needs no synchronization or repair. Do not amend. Do not create an empty
   commit or an unexplained commit after a clean merge. Record the graph, tree,
   OID, changed paths, and validation path. When no commit exists, skip the
   new-commit parts of steps 10 through 13 and continue with exact-head CI and
   review on the unchanged native head.
10. Independently re-read the commit through a quarantine namespace or fresh
    bare repository. Verify the exact parents, merged-base ancestry, commit and
    tree OIDs, complete diff, path inventory, and absence of extra refs,
    commits, parents, or unexplained changes. Reassert every forbidden-path rule
    against that independent delta. Do not execute it.
11. Re-query the complete live state. Require the same open PR, exact bot
    identity, authenticated lineage, head repository, head ref, remote head
    OID, `autoMergeRequest: null`, feedback state, and current `branch` grant.
    Require the current base OID to equal the base used by the candidate. On
    drift, discard the stale result. In the instruction-free context, rebind the
    new policy and restart from section 1. In the exact-base context, stop all
    writes for this process and relaunch at the new exact base. Independently
    prove that the candidate commit is a descendant of this exact authenticated
    old head. Recompute the complete candidate delta and reassert zero forbidden
    workflow or local-Action paths immediately before push.
12. Activate only the reviewed `pushExactCas` one-shot wrapper. It must perform
    its final pinned Git, Node, GitHub CLI, helper, and sealed-path verification
    in the same process that directly spawns the push. Push the verified commit
    to the exact canonical `https://<host>/<owner>/<repository>.git`
    destination with the explicit
    `<expectedNewOid>:refs/heads/<headRefName>` refspec and an exact expected-OID lease for
    `refs/heads/<headRefName>:<authenticatedOldHeadOid>`. This is a
    compare-and-swap only. The independent fast-forward proof in step 11 must
    pass. Never use a bare force, an implicit lease, an empty expected OID, or a
    lease for another ref. Block when the client or host cannot express this
    exact operation or the credential adapter cannot enforce its boundary. Do
    not push when step 9 created no commit. Disable the adapter immediately
    after the attempt. Any rejection is a race signal. Re-read and restart; do
    not override it.
13. Re-query immediately. Require the live `headRefOid` to equal the pushed
    commit. Record the exact non-force parent/head transition as the next
    authorized lineage entry. Begin exact-head CI and review monitoring.

Keep an abandoned standalone clone and its sealed bundle for diagnosis until
its replacement is safe. Remove only temporary state that this run created and
only after its result is published or explicitly recorded as unused. Never
remove a controller checkout, shared Git directory, unrelated worktree, branch,
stash, or bundle.
