"use strict";
// Example for an explicitly approved code-inspection /review eval.
// Promptfoo owns results; run_campaign.py alone owns process cancellation.
const fs = require("node:fs");
const path = require("node:path");
const { randomUUID, createHash } = require("node:crypto");
const { spawn, execFileSync } = require("node:child_process");
const { performance } = require("node:perf_hooks");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function validateCase(trial) {
  if (
    !trial ||
    typeof trial.id !== "string" ||
    !/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}(?![\s\S])/.test(trial.id)
  )
    throw new Error("Unsafe case id");
  for (const field of ["base", "head", "prompt"]) {
    if (typeof trial[field] !== "string" || !trial[field].trim())
      throw new Error(`Case ${field} must be a non-empty string`);
  }
}

function validateArtifactStem(trial) {
  if (
    typeof trial.artifactStem !== "string" ||
    !/^case-[a-z0-9]+(?![\s\S])/.test(trial.artifactStem)
  )
    throw new Error("Missing opaque artifact stem");
}

function validateCases(manifest) {
  if (!Array.isArray(manifest.cases) || !manifest.cases.length)
    throw new Error("Manifest cases must be a non-empty array");
  const ids = new Set();
  for (const trial of manifest.cases) {
    validateCase(trial);
    if (ids.has(trial.id)) throw new Error(`Duplicate case id: ${trial.id}`);
    ids.add(trial.id);
  }
  // Establish unambiguous case identity before checking output destinations.
  const stems = new Set();
  for (const trial of manifest.cases) {
    validateArtifactStem(trial);
    if (stems.has(trial.artifactStem))
      throw new Error(`Duplicate artifact stem: ${trial.artifactStem}`);
    stems.add(trial.artifactStem);
  }
}

function canonicalPath(value) {
  if (typeof value !== "string" || !path.isAbsolute(value))
    throw new Error("Permission paths must be absolute filesystem paths");
  try {
    return fs.realpathSync(value);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    // Outputs and scratch may not exist yet. Resolve their existing ancestor,
    // but reject dangling links instead of guessing their eventual destination.
    try {
      if (fs.lstatSync(value).isSymbolicLink())
        throw new Error("Unresolved permission path symlink");
    } catch (linkError) {
      if (linkError.code !== "ENOENT") throw linkError;
    }
    return path.join(canonicalPath(path.dirname(value)), path.basename(value));
  }
}

function overridesDeny(granted, denied) {
  const relative = path.relative(denied, granted);
  if (
    relative === "" ||
    (!relative.startsWith(`..${path.sep}`) &&
      relative !== ".." &&
      !path.isAbsolute(relative))
  )
    return true;
  // Existing file aliases can also name the same hidden evidence through a
  // hard link. No directory walk or evidence-content read is needed.
  try {
    const a = fs.statSync(granted),
      b = fs.statSync(denied);
    return a.dev === b.dev && a.ino === b.ino;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    return false;
  }
}

function validateTrustedAncestors(resolved, label) {
  const uid = process.geteuid();
  for (let parent = path.dirname(resolved); ; parent = path.dirname(parent)) {
    try {
      const info = fs.statSync(parent);
      if (
        !info.isDirectory() ||
        ![0, uid].includes(info.uid) ||
        (info.mode & 0o022 && !(info.mode & 0o1000))
      )
        throw new Error(`Untrusted ${label} ancestor: ${parent}`);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (parent === path.dirname(parent)) break;
  }
}

function validateResultsDirectory(value) {
  try {
    if (fs.lstatSync(value).isSymbolicLink())
      throw new Error("Results directory must not be a symlink");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const resolved = canonicalPath(value),
    uid = process.geteuid();
  try {
    const info = fs.statSync(resolved);
    if (
      !info.isDirectory() ||
      info.uid !== uid ||
      (info.mode & 0o777) !== 0o700
    )
      throw new Error("Results directory must be user-owned with mode 0700");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  validateTrustedAncestors(resolved, "results");
  return resolved;
}

function validateCasePermissions(roots, scratchRoots) {
  const uid = process.geteuid(),
    stop = performance.now() + 1000,
    pending = [...roots];
  for (const root of roots) validateTrustedAncestors(root, "case");
  let entries = 0;
  while (pending.length) {
    if (++entries > 10000 || performance.now() >= stop)
      throw new Error(
        "Case permission inspection exceeded its bounded metadata limit",
      );
    const value = pending.pop(),
      info = fs.lstatSync(value);
    if (info.uid !== uid || (!info.isSymbolicLink() && info.mode & 0o022))
      throw new Error(
        "Case snapshot must be user-owned and not writable by other users",
      );
    // Symlink permissions are not meaningful. Its owner and parent are checked;
    // approved external runtime targets remain the operator's responsibility.
    if (info.isSymbolicLink() || scratchRoots.has(value)) continue;
    if (info.isDirectory()) {
      const directory = fs.opendirSync(value);
      try {
        for (
          let entry = directory.readSync();
          entry;
          entry = directory.readSync()
        ) {
          if (entries + pending.length >= 10000 || performance.now() >= stop)
            throw new Error(
              "Case permission inspection exceeded its bounded metadata limit",
            );
          pending.push(path.join(value, entry.name));
        }
      } finally {
        directory.closeSync();
      }
    } else if (!info.isFile())
      throw new Error("Case snapshot has an unsupported filesystem entry");
  }
}

function validateHiddenEvidence(
  roots,
  generatedRoots,
  excludedRoots = new Set(),
  allowedPath = null,
) {
  // Reject ambiguous aliases of hidden regular files without inspecting broad
  // granted/runtime trees or reading evidence contents. Use independent copies.
  const visited = new Set(),
    pending = [
      ...roots.map((value) => [value, false]),
      ...generatedRoots.map((value) => [value, true]),
    ];
  const stop = performance.now() + 1000;
  let entries = 0;
  while (pending.length) {
    if (++entries > 10000 || performance.now() >= stop)
      throw new Error(
        "Hidden evidence inspection exceeded its bounded metadata limit",
      );
    const [value, allowMissing] = pending.pop();
    if (excludedRoots.has(value)) continue;
    let info;
    try {
      info = fs.lstatSync(value);
    } catch (error) {
      if (error.code === "ENOENT" && allowMissing) {
        // Only generated destinations may be absent. Configured evidence and
        // disappearing children never establish separation when missing.
        canonicalPath(value);
        continue;
      }
      if (error.code === "ENOENT")
        throw new Error(`Hidden evidence path does not exist: ${value}`);
      throw error;
    }
    if (info.isSymbolicLink())
      throw new Error("Hidden evidence must not contain symlinks");
    if (info.isFile() && info.nlink > 1)
      throw new Error(
        "Hidden evidence must use independent regular files, not hard links",
      );
    if (allowedPath && !allowedPath(value, info))
      throw new Error("Review snapshot contains unapproved Git metadata");
    const identity = `${info.dev}:${info.ino}`;
    if (visited.has(identity)) continue;
    visited.add(identity);
    if (info.isDirectory()) {
      const directory = fs.opendirSync(value);
      try {
        for (
          let entry = directory.readSync();
          entry;
          entry = directory.readSync()
        ) {
          if (entries + pending.length >= 10000 || performance.now() >= stop)
            throw new Error(
              "Hidden evidence inspection exceeded its bounded metadata limit",
            );
          pending.push([path.join(value, entry.name), false]);
        }
      } finally {
        directory.closeSync();
      }
    } else if (!info.isFile())
      throw new Error(
        "Hidden evidence must contain only readable directories and regular files",
      );
  }
}

function validateSkillEntry(entry) {
  let fd;
  try {
    if (!fs.lstatSync(entry).isFile()) throw new Error("not a regular file");
    fd = fs.openSync(entry, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    if (!fs.fstatSync(fd).isFile()) throw new Error("not a regular file");
  } catch {
    throw new Error(
      `Frozen skill entry must be a readable regular file: ${entry}`,
    );
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function validateToolDigests(manifest) {
  if (manifest.toolSha256 === undefined) return;
  const fields = [
    "codexPath",
    "nodePath",
    "gitPath",
    ...["rgPath", "pythonPath"].filter(
      (field) => manifest[field] !== undefined,
    ),
  ];
  const pins = manifest.toolSha256;
  if (
    !pins ||
    typeof pins !== "object" ||
    Array.isArray(pins) ||
    Object.keys(pins).length !== fields.length ||
    fields.some(
      (field) =>
        !Object.hasOwn(pins, field) ||
        typeof pins[field] !== "string" ||
        pins[field].length !== 64 ||
        !/^[a-f0-9]+$/.test(pins[field]),
    )
  )
    throw new Error("Invalid toolSha256 map");
  for (const field of fields) {
    const executable = manifest[field];
    let actual;
    try {
      if (
        typeof executable !== "string" ||
        !path.isAbsolute(executable) ||
        !fs.statSync(executable).isFile()
      )
        throw new Error("Invalid executable");
      fs.accessSync(executable, fs.constants.X_OK);
      actual = createHash("sha256")
        .update(fs.readFileSync(executable))
        .digest("hex");
    } catch {
      throw new Error(
        `Pinned tool must be an absolute readable executable file: ${field}`,
      );
    }
    if (actual !== pins[field])
      throw new Error(`Tool SHA-256 mismatch: ${field}`);
  }
}

function validateReviewRepository(manifest, trial) {
  const stop = performance.now() + 2000;
  const oid = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
  if (![trial.base, trial.head].every((value) => oid.test(value)))
    throw new Error("Review base and head must be full immutable commit IDs");
  if (
    typeof manifest.gitPath !== "string" ||
    !path.isAbsolute(manifest.gitPath)
  )
    throw new Error("A verified absolute gitPath is required");
  const workTree = canonicalPath(trial.repo),
    gitDir = path.join(workTree, ".git");
  if (!fs.lstatSync(gitDir).isDirectory())
    throw new Error(
      "Review repository must have a self-contained .git directory",
    );
  const directories = new Set([
    "",
    "objects",
    "objects/info",
    "objects/pack",
    "refs",
    "refs/heads",
    "refs/tags",
  ]);
  const files = new Set(["HEAD", "config", "index", "packed-refs"]);
  const looseObject = new RegExp(
    `^objects/[0-9a-f]{2}/[0-9a-f]{${trial.head.length - 2}}$`,
  );
  const packedObject = new RegExp(
    `^objects/pack/pack-[0-9a-f]{${trial.head.length}}\\.(pack|idx|rev|bitmap)$`,
  );
  validateHiddenEvidence([gitDir], [], new Set(), (value, info) => {
    const name = path.relative(gitDir, value);
    return info.isDirectory()
      ? directories.has(name) || /^objects\/[0-9a-f]{2}$/.test(name)
      : info.isFile() &&
          (files.has(name) ||
            looseObject.test(name) ||
            packedObject.test(name));
  });
  const headFile = path.join(gitDir, "HEAD");
  if (fs.statSync(headFile).size > trial.head.length + 2)
    throw new Error("Review snapshot HEAD metadata exceeds its bound");
  if (fs.readFileSync(headFile, "utf8").trim() !== trial.head)
    throw new Error("Review snapshot HEAD must be detached at the frozen head");
  const git = (args) => {
    const remaining = Math.floor(stop - performance.now());
    if (remaining <= 0)
      throw new Error("Git snapshot preflight exceeded its deadline");
    try {
      const output = execFileSync(
        manifest.gitPath,
        [
          "-C",
          workTree,
          "--git-dir",
          gitDir,
          "--work-tree",
          workTree,
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "core.fsmonitor=false",
          "-c",
          "protocol.allow=never",
          ...args,
        ],
        {
          encoding: "utf8",
          timeout: remaining,
          maxBuffer: 1024 * 1024,
          env: {
            PATH: "/usr/bin:/bin",
            GIT_CONFIG_NOSYSTEM: "1",
            GIT_CONFIG_GLOBAL: "/dev/null",
            GIT_OPTIONAL_LOCKS: "0",
            GIT_TERMINAL_PROMPT: "0",
            GIT_NO_LAZY_FETCH: "1",
            GIT_NO_REPLACE_OBJECTS: "1",
            GIT_ALLOW_PROTOCOL: "",
          },
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      return args.includes("-z") || args.includes("--null")
        ? output
        : output.trim();
    } catch {
      throw new Error("Git snapshot preflight failed or exceeded its bound");
    }
  };
  // Read only this file through Git's parser. A minimal configuration contract
  // excludes includes, filters and all unapproved checkout/cache settings.
  const configValues = new Map([
    ["core.repositoryformatversion", ["0", "1"]],
    ["extensions.objectformat", [trial.head.length === 64 ? "sha256" : "sha1"]],
    ...["core.filemode", "core.symlinks", "core.trustctime"].map((name) => [
      name,
      ["true"],
    ]),
    ...[
      "core.bare",
      "core.logallrefupdates",
      "core.ignorestat",
      "core.fsmonitor",
    ].map((name) => [name, ["false"]]),
    ...["core.ignorecase", "core.precomposeunicode"].map((name) => [
      name,
      ["true", "false"],
    ]),
    ["core.checkstat", ["default"]],
  ]);
  const checkoutConfig = git([
    "config",
    "--file",
    path.join(gitDir, "config"),
    "--no-includes",
    "--null",
    "--list",
  ]);
  for (const entry of checkoutConfig.split("\0").filter(Boolean)) {
    const separator = entry.indexOf("\n"),
      name = entry.slice(0, separator),
      value = entry.slice(separator + 1);
    if (separator < 1 || !configValues.get(name)?.includes(value))
      throw new Error("Review snapshot has unsupported checkout configuration");
  }
  for (const value of [trial.base, trial.head]) {
    if (
      git([
        "rev-parse",
        "--verify",
        "--end-of-options",
        `${value}^{commit}`,
      ]) !== value
    )
      throw new Error("Review commit does not resolve to its frozen identity");
  }
  if (
    git(["rev-list", "--parents", "--max-count=1", trial.base]) !==
      trial.base ||
    git(["rev-list", "--parents", "--max-count=1", trial.head]) !==
      `${trial.head} ${trial.base}`
  )
    throw new Error(
      "Review snapshot must contain a root base and its direct child head",
    );
  if (git(["for-each-ref", "--format=%(refname)"]) || git(["remote"]))
    throw new Error("Review snapshot must have no named refs or remotes");
  const objectSet = (text) => {
    const values = text.split("\n");
    if (!values.length || values.some((value) => !oid.test(value)))
      throw new Error("Invalid Git object inventory");
    return new Set(values);
  };
  const allowed = objectSet(
    git(["rev-list", "--objects", "--no-object-names", trial.base, trial.head]),
  );
  const stored = objectSet(
    git(["cat-file", "--batch-all-objects", "--batch-check=%(objectname)"]),
  );
  if (
    allowed.size !== stored.size ||
    [...stored].some((value) => !allowed.has(value))
  )
    throw new Error(
      "Review snapshot contains objects outside the approved base/head closure",
    );
  // Compare using Git's built-in checkout normalization, never external
  // filters, diff drivers or text converters. Do not persist index updates.
  const index = git(["ls-files", "-v", "--stage", "-z"]);
  const unchangedGitlinks = [];
  if (manifest.allowUnchangedGitlinks === true) {
    const links = (revision) =>
      git(["ls-tree", "-r", "-z", revision])
        .split("\0")
        .filter((entry) => entry.startsWith("160000 "))
        .sort();
    if (JSON.stringify(links(trial.base)) !== JSON.stringify(links(trial.head)))
      throw new Error("Only unchanged gitlinks are supported");
  }
  for (const entry of index.split("\0").filter(Boolean)) {
    const matched =
      /^H (100644|100755|120000|160000) ([0-9a-f]{40}|[0-9a-f]{64}) 0\t([\s\S]+)$/.exec(
        entry,
      );
    if (!matched)
      throw new Error(
        "Review snapshot index must not suppress checkout checks or use unsupported modes",
      );
    if (matched[3] === ".eval-tmp" || matched[3].startsWith(".eval-tmp/"))
      throw new Error("Review snapshot must not track reserved scratch paths");
    if (matched[1] === "160000") {
      if (manifest.allowUnchangedGitlinks !== true)
        throw new Error("Review snapshot index uses unsupported modes");
      const expected = `160000 commit ${matched[2]}\t${matched[3]}\0`;
      for (const revision of [trial.base, trial.head]) {
        if (
          git(["ls-tree", "-z", revision, "--", `:(literal)${matched[3]}`]) !==
          expected
        )
          throw new Error("Only unchanged gitlinks are supported");
      }
      const location = path.join(workTree, matched[3]);
      try {
        if (
          !fs.lstatSync(location).isDirectory() ||
          fs.readdirSync(location).length
        )
          throw new Error(
            "Gitlink contents must be absent or an empty directory",
          );
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
      unchangedGitlinks.push(matched[3]);
    }
  }
  const diffOptions = [
    "-z",
    "--no-ext-diff",
    "--no-textconv",
    "--ignore-submodules=none",
  ];
  // numstat compares contents when a copied checkout has stale stat metadata.
  if (
    git([
      "diff-index",
      "--cached",
      "--name-only",
      ...diffOptions,
      trial.head,
      "--",
    ]) ||
    git(["diff-files", "--numstat", ...diffOptions, "--"])
  )
    throw new Error(
      "Review snapshot index and tracked worktree must match the frozen head",
    );
  // Without exclude flags, ls-files includes both ignored and untracked files.
  // Compare names case-sensitively regardless of the prepared host's config.
  // Only the validated, denied scratch parent can retain prior trial outputs.
  if (
    git(["-c", "core.ignorecase=false", "ls-files", "--others", "-z", "--"])
      .split("\0")
      .filter(Boolean)
      .some((name) => !name.startsWith(".eval-tmp/"))
  )
    throw new Error(
      "Review snapshot contains extra files outside generated scratch",
    );
  return {
    base: trial.base,
    head: trial.head,
    ...(unchangedGitlinks.length ? { unchangedGitlinks } : {}),
  };
}

function validateTrialLimit(manifest) {
  if (
    manifest.trialMaxMs !== null &&
    (!Number.isSafeInteger(manifest.trialMaxMs) || manifest.trialMaxMs <= 0)
  )
    throw new Error("Invalid trialMaxMs");
}

function buildInvocation(manifest, trial, repeatIndex = 0) {
  validateCases(manifest);
  validateCase(trial);
  validateArtifactStem(trial);
  if (!Number.isSafeInteger(repeatIndex) || repeatIndex < 0)
    throw new Error("Invalid repeatIndex");
  validateTrialLimit(manifest);
  validateToolDigests(manifest);
  const pythonBin = [];
  if (manifest.pythonPath !== undefined) {
    try {
      if (
        typeof manifest.pythonPath !== "string" ||
        !path.isAbsolute(manifest.pythonPath) ||
        !fs.statSync(manifest.pythonPath).isFile()
      )
        throw new Error("Invalid Python executable");
      fs.accessSync(manifest.pythonPath, fs.constants.X_OK);
    } catch {
      throw new Error("pythonPath must be an absolute executable file");
    }
    try {
      if (
        fs.realpathSync(
          path.join(path.dirname(manifest.pythonPath), "python3"),
        ) !== fs.realpathSync(manifest.pythonPath)
      )
        throw new Error("Different interpreter");
    } catch {
      throw new Error(
        "python3 must resolve to pythonPath in its selected directory",
      );
    }
    pythonBin.push(path.dirname(manifest.pythonPath));
  }
  const generatedScratchRoots = new Set();
  for (const item of [trial, ...manifest.cases]) {
    try {
      if (!fs.statSync(item.repo).isDirectory())
        throw new Error("Case repository must be an existing directory");
    } catch (error) {
      if (["ENOENT", "ENOTDIR"].includes(error.code))
        throw new Error("Case repository must be an existing directory");
      throw error;
    }
    const root = path.join(item.repo, ".eval-tmp");
    try {
      const info = fs.lstatSync(root);
      if (info.isSymbolicLink())
        throw new Error("Scratch root must not be a symlink");
      if (!info.isDirectory())
        throw new Error("Scratch root must be a directory");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    generatedScratchRoots.add(canonicalPath(root));
  }
  const repo = canonicalPath(trial.repo);
  validateCasePermissions(
    new Set([repo, ...manifest.cases.map((item) => canonicalPath(item.repo))]),
    generatedScratchRoots,
  );
  validateSkillEntry(manifest.skillEntry);
  validateSkillEntry(path.join(manifest.runtimeRoot, "test-audit/SKILL.md"));
  const scratchRoot = path.join(repo, ".eval-tmp");
  const scratch = path.join(scratchRoot, `repeat-${repeatIndex}`);
  const hiddenScratchRoot = canonicalPath(scratchRoot);
  const resultsDir = validateResultsDirectory(manifest.resultsDir);
  // :tmpdir resolves from this child's TMPDIR, fixed below to the exact scratch
  // directory. Denying that alias would override its explicit write grant.
  const filesystem = {
    ":root": "deny",
    ":minimal": "read",
    ":tmpdir": "write",
    ":slash_tmp": "deny",
  };
  const operatorDeniedPaths = manifest.denyPaths.map(canonicalPath);
  const siblingRepos = manifest.cases
    .filter((c) => c.id !== trial.id)
    .map((c) => canonicalPath(c.repo));
  const requiredDeniedPaths = [...operatorDeniedPaths, ...siblingRepos];
  const deniedPaths = [...requiredDeniedPaths, resultsDir];
  const grants = [
    [repo, "read"],
    [path.dirname(manifest.skillEntry), "read"],
    [path.join(manifest.runtimeRoot, "test-audit"), "read"],
    ...(manifest.runtimeReadPaths || []).map((value) => [value, "read"]),
    [scratch, "write"],
  ];
  // Operator-verified executable/library paths only; never grant a tool prefix.
  for (const [value, access] of grants) {
    const granted = canonicalPath(value);
    if (deniedPaths.some((denied) => overridesDeny(granted, denied)))
      throw new Error(`Permission grant exposes denied evidence: ${value}`);
    if (access !== "write" && overridesDeny(granted, hiddenScratchRoot))
      throw new Error(`Permission grant exposes prior scratch: ${value}`);
    filesystem[granted] = access;
  }
  // A more-specific deny under a broad read remains valid and explicit.
  for (const denied of deniedPaths) filesystem[denied] = "deny";
  // The only exception to this internal scratch-parent deny is this repeat's
  // child write grant. User-declared hidden paths have no such exception.
  filesystem[hiddenScratchRoot] = "deny";
  // Prior scratch belongs to subjects, so its contents may contain tool links.
  // The parent deny and fresh-child grant isolate repeats without walking it.
  validateHiddenEvidence(operatorDeniedPaths, [resultsDir]);
  validateHiddenEvidence(siblingRepos, [], generatedScratchRoots);
  const reviewCommits = validateReviewRepository(manifest, { ...trial, repo });
  const profile = { filesystem, network: { enabled: false } };
  const toml =
    "{filesystem={" +
    Object.entries(filesystem)
      .map(([k, v]) => `${JSON.stringify(k)}=${JSON.stringify(v)}`)
      .join(",") +
    "},network={enabled=false}}";
  const env = {};
  for (const key of [
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
    "TERM",
    "CODEX_HOME",
    "CODEX_THREAD_ID",
    "CODEX_SANDBOX",
    "CODEX_SANDBOX_NETWORK_DISABLED",
    "CODEX_INTERNAL_ORIGINATOR_OVERRIDE",
  ]) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  const gitBin = manifest.gitPath ? [path.dirname(manifest.gitPath)] : [];
  env.PATH = [
    ...new Set([
      ...pythonBin,
      ...gitBin,
      path.dirname(manifest.nodePath),
      ...(manifest.rgPath ? [path.dirname(manifest.rgPath)] : []),
      path.dirname(manifest.codexPath),
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]),
  ].join(path.delimiter);
  env.TMPDIR = scratch;
  env.TMPPREFIX = path.join(scratch, "zsh");
  env.CMUX_CODEX_HOOKS_DISABLED = "1";
  env.CMUX_COMPUTER_USE_MCP_DISABLED = "1";
  // Keep Git behavior scoped to this fixture, independent of host configuration.
  env.GIT_CONFIG_NOSYSTEM = "1";
  env.GIT_CONFIG_GLOBAL = "/dev/null";
  env.GIT_ATTR_NOSYSTEM = "1";
  // Codex shell policy is a separate layer from its own process environment.
  const shellEnv = Object.fromEntries(
    [
      "PATH",
      "TMPDIR",
      "TMPPREFIX",
      "GIT_CONFIG_NOSYSTEM",
      "GIT_CONFIG_GLOBAL",
      "GIT_ATTR_NOSYSTEM",
    ].map((key) => [key, env[key]]),
  );
  const shellSettings =
    "{" +
    Object.entries(shellEnv)
      .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
      .join(",") +
    "}";
  const artifactStem =
    trial.artifactStem + (repeatIndex === 0 ? "" : `.repeat-${repeatIndex}`);
  const paths = Object.fromEntries(
    ["final.txt", "jsonl", "stderr", "receipt.json"].map((suffix) => [
      suffix,
      path.join(resultsDir, `${artifactStem}.${suffix}`),
    ]),
  );
  const args = [
    "--no-daemon",
    "--ask-for-approval",
    "never",
    "exec",
    "--ignore-user-config",
    "--strict-config",
    "--ephemeral",
    "--json",
    "--cd",
    repo,
    "--model",
    manifest.model,
  ];
  for (const setting of [
    `model_reasoning_effort=${JSON.stringify(manifest.effort)}`,
    ...(manifest.serviceTier
      ? [`service_tier=${JSON.stringify(manifest.serviceTier)}`]
      : []),
    'forced_login_method="chatgpt"',
    'default_permissions="eval-trial"',
    `permissions.eval-trial=${toml}`,
    `shell_environment_policy.set=${shellSettings}`,
    'web_search="disabled"',
    "features.memories=false",
    "features.apps=false",
    "features.fast_mode=false",
    "allow_login_shell=false",
    "features.shell_snapshot=false",
    "agents.enabled=false",
    "features.multi_agent=false",
    "mcp_servers.chrome-devtools.enabled=false",
    'mcp_servers.chrome-devtools.command="/usr/bin/false"',
    "mcp_servers.chrome-devtools.args=[]",
    "features.hooks=false",
    "features.plugins=false",
    "features.remote_plugin=false",
    "features.computer_use=false",
    "features.browser_use=false",
    "features.browser_use_external=false",
    "features.in_app_browser=false",
    "features.in_app_local_automation=false",
    "agents.max_concurrent_threads_per_session=2",
    "features.multi_agent_v2=false",
  ])
    args.push("-c", setting);
  // Reserve the native destination before launch; publish it without replacing
  // any existing result only after the child's output streams have closed.
  const pendingFinal = paths["final.txt"] + ".partial";
  args.push("--output-last-message", pendingFinal, "-");
  const inMinutes = manifest.trialMaxMs % 60000 === 0;
  const amount = manifest.trialMaxMs / (inMinutes ? 60000 : 1000);
  const cutoff = `${amount} ${inMinutes ? "minute" : "second"}${amount === 1 ? "" : "s"}`;
  const timing =
    manifest.trialMaxMs === null
      ? "This trial has no work time limit. Complete the requested review; honor cancellation."
      : `This trial has a hard cutoff of ${cutoff}, or less if the shared campaign deadline arrives first. Return a final review before the cutoff; prefer an early grounded result to a timeout.`;
  const prompt = `$review\nRead and follow the frozen review skill at ${manifest.skillEntry}. Its focused test-audit skill is ${path.join(manifest.runtimeRoot, "test-audit/SKILL.md")}.\nBefore reviewing, identify the available tool capabilities and use an ordinary shell command to print the SHA-256 of both skill entry files. User-approved scope for this eval: apply the installed review skill for code inspection, applicable local checks and focused test-audit, and its normal findings format. External security scanners and the separate repository closeout review are excluded by the user for this eval. Report coverage of this code-inspection scope accurately; do not claim those excluded gates passed. Any other required unavailable step remains incomplete. ${timing} State uninspected areas and coverage limits explicitly. Do not invent findings. Use ${scratch} for disposable causal checks; do not modify tracked files. Keep subprocess work in the foreground; do not launch detached or background processes.\nReview range: ${trial.base} to ${trial.head}.\n${trial.prompt}`;
  const submoduleNote = reviewCommits.unchangedGitlinks
    ? "\nUnchanged submodule pointers are retained. Their contents are absent and cannot be reviewed; disclose this coverage limit."
    : "";
  return {
    command: manifest.codexPath,
    args,
    env,
    shellEnv,
    profile,
    prompt: prompt + submoduleNote,
    paths,
    pendingFinal,
    scratch,
    scratchRoot,
    resultsDir,
    reviewCommits,
    repo,
  };
}

function writeExclusiveJson(target, value) {
  const temporary = target + ".tmp";
  fs.writeFileSync(temporary, JSON.stringify(value, null, 2), {
    flag: "wx",
    mode: 0o600,
  });
  try {
    fs.linkSync(temporary, target);
  } finally {
    fs.unlinkSync(temporary);
  }
}

class CodexReviewProvider {
  constructor(options) {
    this.manifest = JSON.parse(
      fs.readFileSync(options.config.manifest, "utf8"),
    );
    validateCases(this.manifest);
  }
  id() {
    return "codex-review";
  }
  async callApi(prompt, context, options = {}) {
    validateCases(this.manifest);
    try {
      validateTrialLimit(this.manifest);
    } catch (error) {
      return { error: error.message };
    }
    const trial = this.manifest.cases.find(
      (c) => c.id === context?.vars?.case_id,
    );
    if (!trial) return { error: "Unknown case_id" };
    if (prompt !== trial.prompt || context?.vars?.input !== trial.prompt)
      return { error: "Promptfoo input does not match the frozen case prompt" };
    const inputSha256 = createHash("sha256").update(prompt).digest("hex");
    const uncapped = process.env.EVAL_CAMPAIGN_EXECUTION_MODE === "uncapped";
    const nullDeadlines = [
      "EVAL_CAMPAIGN_DEADLINE_MONOTONIC",
      "EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC",
      "EVAL_CAMPAIGN_TRIAL_MAX_MS",
    ].every((key) => process.env[key] === "null");
    const cleanupMs = Number(process.env.EVAL_CAMPAIGN_CLEANUP_SECONDS) * 1000;
    if (
      uncapped !== (this.manifest.trialMaxMs === null) ||
      (uncapped &&
        (!nullDeadlines || !Number.isFinite(cleanupMs) || cleanupMs < 2000))
    )
      return { error: "Manifest and supervisor execution mode mismatch" };
    const hard = uncapped
      ? Infinity
      : Number(process.env.EVAL_CAMPAIGN_DEADLINE_MONOTONIC);
    const work = uncapped
      ? Infinity
      : Number(process.env.EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC);
    const max = uncapped
      ? null
      : Number(process.env.EVAL_CAMPAIGN_TRIAL_MAX_MS);
    const registry = process.env.EVAL_CAMPAIGN_REGISTRY_DIR;
    const python = process.env.EVAL_CAMPAIGN_PYTHON_EXECUTABLE,
      registeredExec = process.env.EVAL_CAMPAIGN_REGISTERED_EXEC;
    if (
      (!uncapped &&
        (![hard, work, max].every(Number.isFinite) ||
          work >= hard ||
          max <= 0)) ||
      !registry ||
      !python ||
      !registeredExec
    )
      return {
        error: "Missing or invalid supervisor deadline/registry/launcher",
      };
    if (!uncapped && max > this.manifest.trialMaxMs)
      return { error: "Supervisor trial limit exceeds manifest trialMaxMs" };
    // Sample the owner's Python clock. Its epoch need not match Node's clock.
    // Anchoring before the probe conservatively deducts the entire round trip.
    const sampledAt = performance.now();
    let sampled;
    try {
      const text = execFileSync(
        python,
        ["-I", "-S", "-c", "import time; print(time.monotonic())"],
        {
          encoding: "utf8",
          timeout: 1000,
          maxBuffer: 1024,
          env: {},
          stdio: ["ignore", "pipe", "pipe"],
        },
      ).trim();
      if (!/^\d+(?:\.\d+)?$/.test(text) || !Number.isFinite(Number(text)))
        throw new Error("Invalid monotonic sample");
      sampled = Number(text);
    } catch {
      return {
        error: "Trial not started: supervisor monotonic clock unavailable",
      };
    }
    let hardStop = sampledAt + (hard - sampled) * 1000;
    const beginCleanup = () => {
      if (uncapped)
        hardStop = Math.min(hardStop, performance.now() + cleanupMs);
    };
    const workStop = sampledAt + (work - sampled) * 1000;
    if (workStop <= performance.now() || options.abortSignal?.aborted)
      return { error: "Trial not started: deadline or abort" };
    const repeatIndex =
      context?.repeatIndex === undefined ? 0 : context.repeatIndex;
    const invocation = buildInvocation(
      { ...this.manifest, trialMaxMs: max },
      trial,
      repeatIndex,
    );
    if (workStop <= performance.now() || options.abortSignal?.aborted)
      return { error: "Trial not started: deadline or abort" };
    fs.mkdirSync(invocation.resultsDir, { recursive: true, mode: 0o700 });
    validateResultsDirectory(invocation.resultsDir);
    if (Object.values(invocation.paths).some((file) => fs.existsSync(file)))
      throw new Error("Trial output already exists");
    try {
      fs.mkdirSync(invocation.scratchRoot, { mode: 0o700 });
    } catch (error) {
      if (
        error.code !== "EEXIST" ||
        !fs.lstatSync(invocation.scratchRoot).isDirectory()
      )
        throw error;
    }
    // Reusing a scratch directory could expose a previous attempt's notes.
    fs.mkdirSync(invocation.scratch, { mode: 0o700 });
    // Exclusive files claim this artifact stem before the model can start.
    const stdoutFd = fs.openSync(invocation.paths.jsonl, "wx", 0o600);
    let stderrFd;
    try {
      stderrFd = fs.openSync(invocation.paths.stderr, "wx", 0o600);
      fs.closeSync(fs.openSync(invocation.pendingFinal, "wx", 0o600));
    } catch (error) {
      fs.closeSync(stdoutFd);
      if (stderrFd !== undefined) fs.closeSync(stderrFd);
      throw error;
    }
    const started = new Date().toISOString(),
      start = performance.now();
    const registrationId = randomUUID().replaceAll("-", "");
    const launcher = {
      command: python,
      args: [
        registeredExec,
        "--case-id",
        trial.id,
        "--registration-id",
        registrationId,
        "--started-at",
        started,
        "--",
        invocation.command,
        ...invocation.args,
      ],
    };
    const launchEnv = { ...invocation.env };
    for (const key of [
      "EVAL_CAMPAIGN_EXECUTION_MODE",
      "EVAL_CAMPAIGN_REGISTRY_DIR",
      "EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS",
      "EVAL_CAMPAIGN_DEADLINE_UTC_MS",
      "EVAL_CAMPAIGN_TRIAL_MAX_MS",
      "EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC",
    ])
      launchEnv[key] = process.env[key];
    let buffer = "",
      eventError = null,
      completed = 0,
      original = null;
    let reason = null,
      child,
      capturing = true,
      cancelRequested = false,
      cancelDeliveryFailed = false;
    const requestCancellation = (why) => {
      reason ||= why;
      beginCleanup();
      if (!child?.pid || cancelRequested) return;
      try {
        fs.writeFileSync(
          path.join(registry, `${registrationId}.cancel`),
          JSON.stringify({ reason: why }),
          { flag: "wx", mode: 0o600 },
        );
        cancelRequested = true;
      } catch (error) {
        if (error.code === "EEXIST") cancelRequested = true;
        else {
          cancelDeliveryFailed = true;
          eventError = `Cancellation request failed: ${error.code || error.name}`;
        }
      }
    };
    const onAbort = () => requestCancellation("aborted");
    function event(line) {
      if (!line.trim()) return;
      try {
        const value = JSON.parse(line);
        if (value.type === "turn.completed") {
          completed++;
          original = value.usage ?? null;
        }
        if (value.type === "turn.failed" || value.type === "error")
          eventError = value.error?.message || value.message || value.type;
      } catch {
        eventError = "Invalid JSONL event";
      }
      if (uncapped && eventError) requestCancellation(eventError);
    }
    let exitCode = null,
      exitSignal = null,
      cleanup = null,
      traceComplete = false,
      streamReadFailed = false,
      traceWriteFailed = false;
    const onOutputError = (stream, error) => {
      streamReadFailed = true;
      requestCancellation(`${stream}_read_error: ${error.code || error.name}`);
    };
    const writeTrace = (fd, chunk, stream) => {
      try {
        const bytes = Buffer.from(chunk);
        if (fs.writeSync(fd, bytes, 0, bytes.length) !== bytes.length)
          throw Object.assign(new Error("Short trace write"), {
            code: "SHORT_WRITE",
          });
        return true;
      } catch (error) {
        traceWriteFailed = true;
        original = null;
        buffer = "";
        requestCancellation(
          `${stream}_write_error: ${error.code || error.name}`,
        );
        return false;
      }
    };
    try {
      // The shim captures its own OS identity, waits for the owner's matching
      // acknowledgement, then execs Codex in this same PID. It removes EVAL_CAMPAIGN_*.
      child = spawn(launcher.command, launcher.args, {
        cwd: invocation.repo,
        env: launchEnv,
        detached: true,
        stdio: ["pipe", "pipe", "pipe"],
      });
      child.once("close", () => {
        traceComplete = true;
      });
      child.once("error", (error) =>
        requestCancellation(`spawn_error: ${error.code || error.name}`),
      );
      child.once("exit", (code, signal) => {
        exitCode = code;
        exitSignal = signal;
        beginCleanup();
      });
      child.stdin.on("error", (error) =>
        requestCancellation(`stdin_error: ${error.code || error.name}`),
      );
      child.stdout.on("error", (error) => onOutputError("stdout", error));
      child.stderr.on("error", (error) => onOutputError("stderr", error));
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        if (!capturing) return;
        if (!writeTrace(stdoutFd, chunk, "jsonl") || traceWriteFailed) return;
        buffer += chunk.toString();
        const lines = buffer.split("\n");
        buffer = lines.pop();
        lines.forEach(event);
        if (buffer.length > 8 * 1024 * 1024) {
          buffer = "";
          requestCancellation("JSONL line exceeds limit");
        }
      });
      child.stderr.on("data", (chunk) => {
        if (!capturing) return;
        writeTrace(stderrFd, chunk, "stderr");
      });
      if (child.pid) {
        options.abortSignal?.addEventListener("abort", onAbort, { once: true });
        if (options.abortSignal?.aborted) onAbort();
        else child.stdin.end(invocation.prompt);
      }
    } catch (error) {
      requestCancellation(`provider_error: ${error.code || error.name}`);
    } finally {
      // Pipe closure and the independent owner's receipt are both required.
      // A failed control write cannot leave the provider waiting for cancellation
      // it never delivered. Return incomplete so the owner stops the process tree.
      while (
        !traceComplete &&
        child &&
        !cancelDeliveryFailed &&
        performance.now() < hardStop
      )
        await delay(Math.min(20, hardStop - performance.now()));
      if (child?.pid && !cancelDeliveryFailed) {
        const cleanupPath = path.join(
          registry,
          `${registrationId}.cleanup.json`,
        );
        while (performance.now() < hardStop) {
          // The shim registers before exec. After its pipes close, an absent
          // registration cannot arrive and no matching cleanup receipt can exist.
          if (traceComplete) {
            try {
              fs.lstatSync(path.join(registry, `${registrationId}.json`));
            } catch (error) {
              reason ||=
                error.code === "ENOENT"
                  ? "Launcher exited before supervisor registration"
                  : `Supervisor registration unavailable after launcher exit: ${error.code || error.name}`;
              break;
            }
          }
          try {
            const value = JSON.parse(fs.readFileSync(cleanupPath, "utf8"));
            if (
              value.registration_id !== registrationId ||
              value.pid !== child.pid ||
              value.case_id !== trial.id ||
              typeof value.owned_processes_gone !== "boolean"
            )
              throw new Error("Cleanup receipt identity or result is invalid");
            cleanup = value;
            break;
          } catch (error) {
            if (error.code !== "ENOENT") {
              eventError = `Invalid supervisor cleanup receipt: ${error.message}`;
              break;
            }
          }
          await delay(Math.min(20, Math.max(0, hardStop - performance.now())));
        }
      }
      options.abortSignal?.removeEventListener("abort", onAbort);
      if (!traceComplete)
        requestCancellation(
          uncapped
            ? "Trace pipes did not close within cleanup allowance"
            : "Trace pipes did not close before the shared deadline",
        );
      capturing = false;
      child?.stdin.destroy();
      child?.stdout.destroy();
      child?.stderr.destroy();
      child?.unref();
      fs.closeSync(stdoutFd);
      fs.closeSync(stderrFd);
      if (!traceWriteFailed) event(buffer);
      if (traceComplete) {
        try {
          fs.linkSync(invocation.pendingFinal, invocation.paths["final.txt"]);
          fs.unlinkSync(invocation.pendingFinal);
        } catch (error) {
          reason ||= `final_output_error: ${error.code || error.name}`;
        }
      }
    }
    const usage = {
      prompt: null,
      cached: null,
      completion: null,
      latencyMs: performance.now() - start,
      cost: null,
    };
    if (
      traceComplete &&
      !streamReadFailed &&
      !traceWriteFailed &&
      completed === 1 &&
      original &&
      typeof original === "object"
    ) {
      for (const [dest, source] of [
        ["prompt", "input_tokens"],
        ["cached", "cached_input_tokens"],
        ["completion", "output_tokens"],
      ]) {
        if (Number.isSafeInteger(original[source]) && original[source] >= 0)
          usage[dest] = original[source];
      }
    }
    let output = "";
    try {
      output = fs.readFileSync(invocation.paths["final.txt"], "utf8");
    } catch {
      /* An interrupted trial may have no final message. */
    }
    const cancellation =
      cleanup && cleanup.reason !== "root_exit"
        ? ["trial_deadline", "campaign_deadline"].includes(cleanup.reason)
          ? "trial_or_campaign_deadline"
          : `supervisor_${cleanup.reason}`
        : null;
    const error =
      (cancelDeliveryFailed
        ? `${eventError}; original request: ${reason}`
        : null) ||
      reason ||
      eventError ||
      cancellation ||
      (exitCode !== 0
        ? `Codex exited ${exitCode} (${exitSignal || "no signal"})`
        : null) ||
      (completed !== 1
        ? `Expected one completed turn; observed ${completed}`
        : null) ||
      (!output.trim() ? "No final review output" : null) ||
      (cleanup?.owned_processes_gone !== true
        ? "Owned process cleanup unverified"
        : null);
    const receipt = {
      case_id: trial.id,
      repeat_index: repeatIndex,
      registration_id: registrationId,
      started_at: started,
      ended_at: new Date().toISOString(),
      exit_code: exitCode,
      exit_signal: exitSignal,
      error,
      cleanup,
      cancellation_delivery_failed: cancelDeliveryFailed,
      trace_complete: traceComplete && !streamReadFailed && !traceWriteFailed,
      original_usage: original,
      usage,
      usage_scope: "CLI turn only; descendant usage coverage unverified",
      trial_max_ms: max,
      execution_mode: uncapped ? "uncapped" : "bounded",
      completed_turns: completed,
      paths: invocation.paths,
      prompt: invocation.prompt,
      input_sha256: inputSha256,
      review_commits: invocation.reviewCommits,
      command: invocation.command,
      args: invocation.args,
      launcher,
      permission_profile: invocation.profile,
    };
    writeExclusiveJson(invocation.paths["receipt.json"], receipt);
    return {
      output,
      ...(error ? { error } : {}),
      metadata: {
        case_id: trial.id,
        repeatIndex,
        input_sha256: inputSha256,
        review_commits: invocation.reviewCommits,
        evalCreator: { usage, usageScope: receipt.usage_scope },
        receipt: invocation.paths["receipt.json"],
      },
    };
  }
}
module.exports = CodexReviewProvider;
module.exports.buildInvocation = buildInvocation;
