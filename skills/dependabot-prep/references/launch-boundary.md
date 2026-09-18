# Dependabot preparation: launch boundary

Paths such as `scripts/` and `fixtures/` are relative to the skill root,
not this reference directory or the candidate repository. Resolve them from
the loaded skill location. Numbered sections refer to `SEALED-LEGACY.md`.

Archived sealed-launcher procedure; see `SEALED-LEGACY.md`. It is not part of
the active workflow in `SKILL.md`, which needs no launcher.

## Pre-model write boundary

Write mode requires a trusted launcher boundary before the model process starts.
An in-model check cannot repair instructions that the runtime already loaded.
An existing interactive session that did not start through this boundary stays
read-only for its complete lifetime. Stop it and relaunch it through the trusted
boundary before granting any write class.

The launcher and any runtime-specific instruction-isolation adapter must be
operator-owned regular files outside every repository and candidate clone. Pin
their canonical resolved paths and reviewed SHA-256 digests in operator
configuration. The launcher must verify those pins, the complete instruction-bundle pins, and
the exact runtime binary, version, and instruction-discovery configuration before
it starts the model. A missing file, link, candidate-writable path component, digest
mismatch, or configuration drift keeps the invocation read-only.

The launcher must establish exactly one of these launch contexts:

1. An operator-owned, repository-instruction-free directory outside every
   checkout. Its runtime-discoverable ancestors must contain no repository
   instruction file. Keep this directory as the runtime project root and model
   working directory for the complete invocation.
2. A trusted pre-model materialization of the authenticated exact live base OID.
   Before launch, prove that the checkout and index are clean at that OID, that
   its complete materialized tree contains only ordinary files and directories,
   and that every instruction file the runtime can discover has exact bytes from
   that OID. Reject symlinks, gitlinks, extra files, alternate instruction roots,
   and a base that moves before launch.

Record the selected launch-context mode in the invocation ledger. Before a
write-capable launch for `all`, inventory the exact live base OID of every
target. An instruction-free process may bind and rebind independent policy
snapshots for multiple bases. One exact-base process is permanently bound to
the one base OID that it materialized before launch. It must not process a PR
whose exact live base differs from that OID. A multi-base `all` write run must
therefore use the instruction-free context or start one separately verified
exact-base launcher process for each distinct base OID. Do not assign one PR to
more than one process or let one exact-base process span two base OIDs.

Never use a candidate clone, candidate branch, mutable controller checkout, or
unverified repository directory as the model launch root. Access candidate
clones only through the fixed paths and operations that passed the current-host
test below. Do not change the runtime project root or model working directory to
a candidate path during the invocation.

Before a write-capable launch on each host, the reviewed launcher must test the
exact runtime binary, version, configuration, launcher, adapter, and candidate
access operations that production will use. The no-credential test must create
a disposable candidate clone with unique sentinel instructions in every
supported repository-instruction filename and discovery location. It must make
the runtime access those paths through the same read, edit, and command-working-
directory mechanisms used by this skill. Require machine-verifiable runtime
trace evidence, or an equally independent fail-closed observation, that no
candidate instruction was imported into the active instruction set. A model's
statement that it ignored the sentinel is not evidence. Bind the successful
result to the host and exact inputs. Repeat the test after any bound input or
runtime instruction-discovery behavior changes. If the runtime cannot prove
this isolation, keep that runtime read-only.

The same test must prove that those exact access mechanisms start no
candidate-controlled process, load no candidate configuration, and make no
candidate-triggered network request. Include hostile `.envrc`, autoenv, shell
startup, Git hook, editor, formatter, language-server, file-watcher, and package
tool configuration with distinct filesystem and network sentinels. Require no
sentinel effect and complete process and network observations. Never start a
runtime command shell or PTY with its working directory in the candidate clone.
Use a reviewed direct-argv adapter for trusted Git, with the candidate working
directory applied immediately before the Git `exec`, or start the runtime's
command mechanism in the trusted launch directory and pass the validated clone
through a tested non-shell `-C` or equivalent argument. Do not interpolate
candidate bytes into a command. If the runtime cannot prove this no-execution
and no-network property, keep every write class disabled.
