/*
# check: serial
*/
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ChildProcess, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import Provider, { buildInvocation } from "./codex-review-provider.cjs";

const pythonProbe = spawnSync(
  process.env.PYTHON || "python3",
  [
    "-c",
    'import json,psutil,sys,time; print(json.dumps({"executable":sys.executable,"monotonic":time.monotonic(),"utc_ms":time.time()*1000}))',
  ],
  { encoding: "utf8" },
);
assert.equal(
  pythonProbe.status,
  0,
  "Provider controls require Python with psutil. Install eval-creator/requirements.txt before this suite.",
);
const python = JSON.parse(pythonProbe.stdout);
const shim = fileURLToPath(
  new URL("../../scripts/registered_exec.py", import.meta.url),
);
const wallNow = Date.now;

function createFixtureRepo(repo, head = "b".repeat(40)) {
  fs.mkdirSync(repo);
  fs.mkdirSync(path.join(repo, ".git"));
  fs.writeFileSync(path.join(repo, ".git/HEAD"), head + "\n");
}

// The fake CLI cooperates through files. Only the fake controller can stop it.
// Real process identity and signal behavior belong to the supervisor tests.
function fixture(mode = "success", settings = {}) {
  const root = fs.realpathSync(
    fs.mkdtempSync(path.join(os.tmpdir(), "codex-provider-")),
  );
  const repo = path.join(root, "repo"),
    registry = path.join(root, "registry");
  createFixtureRepo(repo);
  fs.mkdirSync(registry, { mode: 0o700 });
  const stop = path.join(root, "stop"),
    exited = path.join(root, "exited");
  const ready = path.join(root, "ready"),
    fake = path.join(root, "fake-codex");
  const base = "a".repeat(40),
    head = "b".repeat(40),
    tree = "c".repeat(40);
  const gitPath = path.join(root, "fake-git"),
    gitState = path.join(root, "git-state.json");
  const gitRequests = path.join(root, "git-requests.jsonl");
  fs.writeFileSync(gitState, JSON.stringify({ base, head, tree }));
  // The real preflight keeps its two-second bound. Avoid repeated Node startups
  // for synthetic Git queries; use the already-qualified Python fixture runtime.
  fs.writeFileSync(
    gitPath,
    `#!${python.executable}
import json, os, sys
from pathlib import Path
state = json.loads(Path(${JSON.stringify(gitState)}).read_text())
args = sys.argv[1:]
with Path(${JSON.stringify(gitRequests)}).open("a") as log:
    log.write(json.dumps({"args": args, "env": dict(os.environ)}, separators=(",", ":"), ensure_ascii=False) + chr(10))
def terminated(entries):
    if entries:
        sys.stdout.write(chr(0).join(entries) + chr(0))
if "rev-parse" in args:
    ref = args[-1].removesuffix("^{commit}")
    if state.get("missing") == ref or ref not in (state["base"], state["head"]):
        sys.exit(128)
    print(ref)
elif "--parents" in args:
    print(state["base"] if args[-1] == state["base"] else state["head"] + " " + (state.get("parent") or state["base"]))
elif "for-each-ref" in args:
    if state.get("ref"): print(state["ref"])
elif "remote" in args:
    if state.get("remote"): print(state["remote"])
elif "--objects" in args:
    print(chr(10).join([state["base"], state["head"], state["tree"]]))
elif "cat-file" in args:
    print(chr(10).join([state["base"], state["head"], state["tree"]] + ([state["extra"]] if state.get("extra") else [])))
elif "config" in args:
    if "--list" in args:
        config = dict(state.get("config") or {})
        if state.get("worktree"): config["core.worktree"] = "inert-worktree-setting"
        if state.get("filter"): config[state["filter"]] = "inert-filter-setting"
        terminated([key + chr(10) + value for key, value in config.items()])
    elif args[-1] == r"^core\\.worktree$":
        if state.get("worktree"): print("core.worktree")
        else: sys.exit(1)
    elif "--type=bool" in args:
        entries = [key + chr(10) + value for key, value in (state.get("config") or {}).items()]
        if not entries: sys.exit(1)
        terminated(entries)
    elif state.get("filter"):
        terminated([state["filter"]])
    else: sys.exit(1)
elif "diff-index" in args:
    if state.get("indexChange"): terminated([state["indexChange"]])
elif "diff-files" in args:
    if state.get("worktreeChange"): terminated([state["worktreeChange"]])
elif "ls-files" in args:
    if "--others" in args:
        entries = state.get("others") or []
    elif "--stage" in args:
        entries = state.get("indexStages")
        if entries is None:
            entries = [entry[:2] + "100644 " + state["tree"] + " 0" + chr(9) + entry[2:] for entry in state.get("indexEntries") or []]
    else:
        entries = state.get("indexEntries") or []
    terminated(entries)
else:
    sys.exit(129)
`,
    { mode: 0o700 },
  );
  fs.writeFileSync(
    fake,
    `#!${process.execPath}\n
const fs = require('node:fs');
process.on('exit', () => fs.writeFileSync(${JSON.stringify(exited)}, 'closed'));
let prompt = ''; process.stdin.on('data', chunk => prompt += chunk);
process.stdin.on('end', () => {
  fs.writeFileSync(${JSON.stringify(ready)}, 'ready');
  if (['hang','error-hang','invalid-hang'].includes(${JSON.stringify(mode)})) {
    console.log(JSON.stringify({type:'offline.partial',message:'preserve this prefix'}));
    if (${JSON.stringify(mode)} === 'error-hang') console.log(JSON.stringify({type:'turn.failed',error:{message:'terminal fixture failure'}}));
    if (${JSON.stringify(mode)} === 'invalid-hang') console.log('invalid-json');
    setInterval(() => { if (fs.existsSync(${JSON.stringify(stop)})) process.exit(0); }, 5);
    setTimeout(() => process.exit(91), 4000); // Owned fixture backstop only.
    return;
  }
  if (${JSON.stringify(mode)} === 'error') {
    console.error('controlled stderr');
    console.log(JSON.stringify({type:'turn.failed',error:{message:'controlled failure'}}));
    process.exitCode = 3; return;
  }
  if (${JSON.stringify(mode)} === 'stderr-success') console.error('controlled UTF-8 stderr: €');
  fs.writeFileSync(process.argv[process.argv.indexOf('--output-last-message')+1], JSON.stringify({
    noApiKey:!process.env.OPENAI_API_KEY && !process.env.CODEX_API_KEY,
    home:process.env.HOME, marker:process.env.CODEX_THREAD_ID, scratch:process.env.TMPDIR,
    supervisorEnvAbsent:!Object.keys(process.env).some(key => key.startsWith('EVAL_CAMPAIGN_')),
    prompt, args:process.argv.slice(2)
  }));
  console.log(JSON.stringify({type:'turn.completed', ...(${JSON.stringify(mode)} === 'missing' ? {} :
    {usage:{input_tokens:31,cached_input_tokens:7,output_tokens:11}})}));
});\n`,
    { mode: 0o700 },
  );
  const manifest = {
    codexPath: fake,
    nodePath: process.execPath,
    gitPath,
    model: "configured-model",
    effort: "max",
    trialMaxMs: Object.hasOwn(settings, "trialMaxMs")
      ? settings.trialMaxMs
      : 3000,
    runtimeRoot: path.join(root, "runtime"),
    skillEntry: path.join(root, "runtime/review/SKILL.md"),
    resultsDir: path.join(root, "results"),
    denyPaths: [path.join(root, "private")],
    cases: [
      {
        id: "original-pr",
        artifactStem: "case-a",
        repo,
        base,
        head,
        prompt: "A neutral review request.",
      },
    ],
  };
  fs.mkdirSync(manifest.denyPaths[0]);
  for (const entry of [
    manifest.skillEntry,
    path.join(manifest.runtimeRoot, "test-audit/SKILL.md"),
  ]) {
    fs.mkdirSync(path.dirname(entry), { recursive: true });
    fs.writeFileSync(entry, "# Frozen offline fixture\n");
  }
  const file = path.join(root, "manifest.json");
  fs.writeFileSync(file, JSON.stringify(manifest));
  const oldEnv = { ...process.env };
  const hardMs = settings.hardMs ?? 4500;
  Object.assign(process.env, {
    EVAL_CAMPAIGN_REGISTRY_DIR: registry,
    EVAL_CAMPAIGN_DEADLINE_UTC_MS: String(Date.now() + hardMs),
    EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS: String(Date.now() + hardMs - 100),
    EVAL_CAMPAIGN_TRIAL_MAX_MS: String(manifest.trialMaxMs),
    EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC: String(
      python.monotonic + (Date.now() - python.utc_ms + hardMs - 100) / 1000,
    ),
    EVAL_CAMPAIGN_DEADLINE_MONOTONIC: String(
      python.monotonic + (Date.now() - python.utc_ms + hardMs) / 1000,
    ),
    EVAL_CAMPAIGN_PYTHON_EXECUTABLE: python.executable,
    EVAL_CAMPAIGN_REGISTERED_EXEC: shim,
  });
  process.env.EVAL_CAMPAIGN_EXECUTION_MODE =
    manifest.trialMaxMs === null ? "uncapped" : "bounded";
  if (manifest.trialMaxMs === null)
    Object.assign(process.env, {
      EVAL_CAMPAIGN_DEADLINE_MONOTONIC: "null",
      EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC: "null",
      EVAL_CAMPAIGN_TRIAL_MAX_MS: "null",
      EVAL_CAMPAIGN_DEADLINE_UTC_MS: "null",
      EVAL_CAMPAIGN_WORK_DEADLINE_UTC_MS: "null",
      EVAL_CAMPAIGN_CLEANUP_SECONDS: "2",
    });
  return {
    root,
    registry,
    stop,
    ready,
    exited,
    manifest,
    oldEnv,
    gitState,
    gitRequests,
    provider: new Provider({ config: { manifest: file } }),
  };
}

async function controlled(
  f,
  options = {},
  controller = {},
  context = { vars: { case_id: "original-pr" } },
) {
  const oldKill = process.kill,
    oldChildKill = ChildProcess.prototype.kill,
    oldEmit = ChildProcess.prototype.emit;
  process.kill = ChildProcess.prototype.kill = () => {
    throw new Error("Provider attempted an unowned raw signal");
  };
  const closed = new Set();
  ChildProcess.prototype.emit = function (event, ...args) {
    if (event === "close") closed.add(this.pid);
    return oldEmit.call(this, event, ...args);
  };
  const previousRegistrations = new Set(fs.readdirSync(f.registry));
  let registration,
    registrationText,
    published = false,
    requested = false,
    controllerReason = "root_exit";
  const poll = setInterval(() => {
    const name = fs
      .readdirSync(f.registry)
      .find(
        (file) =>
          /^[0-9a-f]{32}\.json$/.test(file) && !previousRegistrations.has(file),
      );
    if (!name) return;
    const text = fs.readFileSync(path.join(f.registry, name), "utf8");
    registration ??= JSON.parse(text);
    registrationText ??= text;
    const pid = registration.pid;
    const registrationId = registration.registration_id;
    const ack = path.join(f.registry, `${registrationId}.ready.json`);
    if (!controller.noAck && !fs.existsSync(ack)) {
      fs.writeFileSync(
        ack + ".tmp",
        JSON.stringify({
          registration_id: registrationId,
          pid,
          create_time: registration.create_time + (controller.wrongAck ? 1 : 0),
        }),
        { flag: "wx" },
      );
      fs.renameSync(ack + ".tmp", ack);
    }
    if (fs.existsSync(path.join(f.registry, `${registrationId}.cancel`))) {
      requested = true;
      controllerReason = "provider_abort";
      fs.writeFileSync(f.stop, "cancelled by controller");
    } else if (
      controller.timeout &&
      wallNow() >= Date.parse(registration.started_at) + f.manifest.trialMaxMs
    ) {
      controllerReason = "trial_deadline";
      fs.writeFileSync(f.stop, "expired in controller");
    }
    if (closed.has(pid) && !published && !controller.omitReceipt) {
      const target = path.join(f.registry, `${registrationId}.cleanup.json`);
      fs.writeFileSync(
        target + ".tmp",
        JSON.stringify({
          case_id: controller.wrongCase ? "another-case" : registration.case_id,
          registration_id: controller.wrongRegistration
            ? "0".repeat(32)
            : registrationId,
          pid,
          reason: controllerReason,
          owned_processes_gone: controller.ownedGone ?? true,
          signals: [],
          unobserved_descendants_verified: false,
        }),
        { flag: "wx" },
      );
      fs.renameSync(target + ".tmp", target);
      published = true;
    }
  }, 5);
  try {
    const input = f.provider.manifest.cases.find(
      (c) => c.id === context.vars?.case_id,
    )?.prompt;
    const rendered = Object.hasOwn(controller, "renderedPrompt")
      ? controller.renderedPrompt
      : input;
    const result = await f.provider.callApi(
      rendered,
      { ...context, vars: { input, ...context.vars } },
      options,
    );
    if (registration)
      assert.equal(
        fs.readFileSync(
          path.join(f.registry, `${registration.registration_id}.json`),
          "utf8",
        ),
        registrationText,
      );
    return {
      result,
      requested,
      registration,
      receipt:
        result.metadata && JSON.parse(fs.readFileSync(result.metadata.receipt)),
    };
  } finally {
    clearInterval(poll);
    process.kill = oldKill;
    ChildProcess.prototype.kill = oldChildKill;
    ChildProcess.prototype.emit = oldEmit;
    fs.writeFileSync(f.stop, "fixture cleanup");
  }
}

async function dispose(f) {
  const until = wallNow() + 4200;
  while (
    fs.existsSync(f.ready) &&
    !fs.existsSync(f.exited) &&
    wallNow() < until
  )
    await new Promise((resolve) => setTimeout(resolve, 10));
  process.env = f.oldEnv;
  fs.rmSync(f.root, { recursive: true, force: true });
}

test("an invalid manifest limit cannot be replaced by the controller cap", async () => {
  const f = fixture();
  delete f.provider.manifest.trialMaxMs;
  try {
    const { result } = await controlled(f);
    assert.match(result.error, /Invalid trialMaxMs/);
    assert.equal(fs.existsSync(f.ready), false);
  } finally {
    await dispose(f);
  }
});

test("uncapped abort with a failed control write returns incomplete to its owner", async () => {
  const f = fixture("hang", { trialMaxMs: null });
  const abort = new AbortController(),
    originalWrite = fs.writeFileSync;
  let attempts = 0;
  fs.writeFileSync = (file, ...args) => {
    if (String(file).endsWith(".cancel")) {
      attempts++;
      throw Object.assign(new Error("control write failed"), { code: "EIO" });
    }
    return originalWrite(file, ...args);
  };
  const poll = setInterval(() => {
    if (fs.existsSync(f.ready)) abort.abort();
  }, 10);
  try {
    const { result, receipt } = await controlled(f, {
      abortSignal: abort.signal,
    });
    assert.ok(attempts > 0);
    assert.match(result.error, /Cancellation request failed: EIO/);
    assert.equal(receipt.cancellation_delivery_failed, true);
    assert.equal(receipt.cleanup, null);
    assert.equal(receipt.trace_complete, false);
  } finally {
    clearInterval(poll);
    fs.writeFileSync = originalWrite;
    await dispose(f);
  }
});

test("uncapped launcher exit before registration returns incomplete without waiting for owner cleanup", async (t) => {
  for (const failure of ["missing-script", "registration-EIO"])
    await t.test(failure, async () => {
      const f = fixture("success", { trialMaxMs: null });
      const launcher = path.join(f.root, "pre-registration.py");
      if (failure === "registration-EIO")
        fs.writeFileSync(
          launcher,
          `import errno, os, runpy
def refuse_registration(*args, **kwargs):
    raise OSError(errno.EIO, 'controlled registration failure')
os.link = refuse_registration
runpy.run_path(${JSON.stringify(shim)}, run_name='__main__')
`,
        );
      process.env.EVAL_CAMPAIGN_REGISTERED_EXEC = launcher;
      const abort = new AbortController(),
        originalRead = fs.readFileSync,
        originalEmit = ChildProcess.prototype.emit;
      let closedPid,
        watchdog,
        forcedRelease = false;
      // This is a test backstop, not a production deadline. Release the old
      // impossible receipt wait so a regression fails without hanging the suite.
      fs.readFileSync = function (file, ...args) {
        if (forcedRelease && String(file).endsWith(".cleanup.json"))
          throw Object.assign(new Error("test receipt-wait backstop"), {
            code: "TEST_TIMEOUT",
          });
        return originalRead.call(this, file, ...args);
      };
      ChildProcess.prototype.emit = function (event, ...args) {
        if (event === "close") {
          closedPid = this.pid;
          if (failure === "missing-script") abort.abort(); // The old provider still waits after this abort.
          watchdog = setTimeout(() => {
            forcedRelease = true;
          }, 250);
        }
        return originalEmit.call(this, event, ...args);
      };
      try {
        const { result, receipt, registration } = await controlled(f, {
          abortSignal: abort.signal,
        });
        assert.equal(
          forcedRelease,
          false,
          "provider waited for an impossible cleanup receipt until the test backstop",
        );
        assert.ok(closedPid > 0);
        assert.equal(
          spawnSync(python.executable, [
            "-c",
            "import psutil,sys; sys.exit(1 if psutil.pid_exists(int(sys.argv[1])) else 0)",
            String(closedPid),
          ]).status,
          0,
          "launcher was reaped",
        );
        assert.equal(registration, undefined);
        assert.equal(receipt.exit_code, 2);
        assert.equal(receipt.cleanup, null);
        assert.equal(receipt.trace_complete, true);
        assert.equal(receipt.completed_turns, 0);
        assert.deepEqual(
          [
            receipt.usage.prompt,
            receipt.usage.cached,
            receipt.usage.completion,
          ],
          [null, null, null],
        );
        assert.match(
          result.error,
          failure === "missing-script"
            ? /aborted/
            : /Launcher exited before supervisor registration/,
        );
        assert.equal(fs.existsSync(f.ready), false, "subject never started");
        assert.ok(
          fs.readdirSync(f.registry).every((name) => name.endsWith(".cancel")),
          "no owner registration or fabricated cleanup",
        );
        assert.match(
          fs.readFileSync(receipt.paths.stderr, "utf8"),
          failure === "missing-script"
            ? /can't open file/
            : /OSError:.*controlled registration failure/,
        );
      } finally {
        clearTimeout(watchdog);
        fs.readFileSync = originalRead;
        ChildProcess.prototype.emit = originalEmit;
        await dispose(f);
      }
    });
});

test("completed output preserves usage and states the lower controller cap without API fallback", async () => {
  const f = fixture();
  process.env.EVAL_CAMPAIGN_TRIAL_MAX_MS = "2000";
  process.env.OPENAI_API_KEY = "fake-sentinel";
  process.env.CODEX_API_KEY = "fake-sentinel";
  process.env.CODEX_THREAD_ID = "retained";
  try {
    const { result, receipt, registration } = await controlled(f);
    assert.equal(result.error, undefined);
    assert.equal(f.provider.id(), "codex-review");
    const observed = JSON.parse(result.output);
    assert.equal(observed.noApiKey, true);
    assert.equal(observed.home, f.oldEnv.HOME);
    assert.equal(observed.marker, "retained");
    assert.equal(observed.supervisorEnvAbsent, true);
    assert.equal(
      observed.args[observed.args.indexOf("--model") + 1],
      "configured-model",
    );
    assert.ok(observed.args.includes('model_reasoning_effort="max"'));
    assert.ok(!observed.args.some((arg) => arg.startsWith("service_tier=")));
    assert.match(observed.prompt, /hard cutoff of 2 seconds/);
    assert.ok(!observed.prompt.includes("hard cutoff of 3 seconds"));
    assert.match(observed.prompt, /\$review/);
    assert.match(observed.prompt, /test-audit\/SKILL\.md/);
    assert.ok(!observed.prompt.includes("original-pr"));
    assert.equal(receipt.cleanup.owned_processes_gone, true);
    assert.equal(receipt.cleanup.group_gone, undefined);
    assert.equal(registration.pid, registration.pgid);
    assert.equal(registration.case_id, "original-pr");
    assert.match(registration.registration_id, /^[0-9a-f]{32}$/);
    assert.equal(receipt.registration_id, registration.registration_id);
    assert.equal(receipt.cleanup.registration_id, registration.registration_id);
    assert.equal(typeof registration.create_time, "number");
    assert.equal(receipt.launcher.command, python.executable);
    assert.equal(
      receipt.launcher.args[
        receipt.launcher.args.indexOf("--registration-id") + 1
      ],
      registration.registration_id,
    );
    assert.deepEqual(receipt.original_usage, {
      input_tokens: 31,
      cached_input_tokens: 7,
      output_tokens: 11,
    });
    assert.deepEqual(
      [receipt.usage.prompt, receipt.usage.cached, receipt.usage.completion],
      [31, 7, 11],
    );
    assert.match(
      fs.readFileSync(receipt.paths.jsonl, "utf8"),
      /turn.completed/,
    );
    assert.ok(!fs.existsSync(receipt.paths["final.txt"] + ".partial"));
  } finally {
    await dispose(f);
  }
});

test("missing usage stays unknown after an otherwise completed review", async () => {
  const f = fixture("missing");
  try {
    const { result, receipt } = await controlled(f);
    assert.equal(result.error, undefined);
    assert.deepEqual(
      [receipt.usage.prompt, receipt.usage.cached, receipt.usage.completion],
      [null, null, null],
    );
  } finally {
    await dispose(f);
  }
});

test("failed native turn retains stderr and does not become a successful empty review", async () => {
  const f = fixture("error");
  try {
    const { result, receipt } = await controlled(f);
    assert.match(result.error, /controlled failure/);
    assert.equal(receipt.exit_code, 3);
    assert.equal(receipt.completed_turns, 0);
    assert.equal(receipt.usage.prompt, null);
    assert.match(
      fs.readFileSync(receipt.paths.stderr, "utf8"),
      /controlled stderr/,
    );
  } finally {
    await dispose(f);
  }
});

test("abort requests controller cancellation and preserves the incomplete trace without signaling", async () => {
  const f = fixture("hang"),
    abort = new AbortController();
  const trigger = setInterval(() => {
    if (fs.existsSync(f.ready)) abort.abort();
  }, 5);
  try {
    const { result, receipt, requested } = await controlled(f, {
      abortSignal: abort.signal,
    });
    assert.equal(result.error, "aborted");
    assert.equal(requested, true);
    assert.equal(receipt.cleanup.reason, "provider_abort");
    assert.equal(receipt.cleanup.owned_processes_gone, true);
    assert.match(
      fs.readFileSync(receipt.paths.jsonl, "utf8"),
      /preserve this prefix/,
    );
    assert.equal(receipt.usage.prompt, null);
  } finally {
    clearInterval(trigger);
    await dispose(f);
  }
});

test("controller timeout keeps quality and unavailable usage unknown", async () => {
  const f = fixture("hang", { trialMaxMs: 1000 });
  try {
    const { result, receipt, requested } = await controlled(
      f,
      {},
      { timeout: true },
    );
    assert.equal(result.error, "trial_or_campaign_deadline");
    assert.equal(requested, false);
    assert.equal(receipt.cleanup.reason, "trial_deadline");
    assert.equal(receipt.completed_turns, 0);
    assert.deepEqual(
      [receipt.usage.prompt, receipt.usage.cached, receipt.usage.completion],
      [null, null, null],
    );
  } finally {
    await dispose(f);
  }
});

test("missing, mismatched or negative cleanup evidence cannot establish success", async () => {
  for (const controller of [
    { omitReceipt: true },
    { wrongCase: true },
    { ownedGone: false },
  ]) {
    const f = fixture("success", { hardMs: 3000, trialMaxMs: 2000 });
    try {
      const { result } = await controlled(f, {}, controller);
      assert.match(result.error, /cleanup/i);
    } finally {
      await dispose(f);
    }
  }
});

test("cleanup from a different registration cannot establish success for the same PID and case", async () => {
  const f = fixture();
  try {
    const { result, receipt, registration } = await controlled(
      f,
      {},
      { wrongRegistration: true },
    );
    const provided = JSON.parse(
      fs.readFileSync(
        path.join(f.registry, `${registration.registration_id}.cleanup.json`),
      ),
    );
    assert.equal(provided.pid, registration.pid);
    assert.equal(provided.case_id, registration.case_id);
    assert.notEqual(provided.registration_id, registration.registration_id);
    assert.match(
      result.error,
      /Invalid supervisor cleanup receipt: Cleanup receipt identity or result is invalid/,
    );
    assert.equal(receipt.cleanup, null);
  } finally {
    await dispose(f);
  }
});

test("absent or wrong owner acknowledgement prevents the fake model from starting", async () => {
  for (const controller of [{ noAck: true }, { wrongAck: true }]) {
    const f = fixture("success", { trialMaxMs: 1200 });
    try {
      const { result, receipt } = await controlled(f, {}, controller);
      assert.match(result.error, /Codex exited 2/);
      assert.equal(receipt.completed_turns, 0);
      assert.equal(receipt.usage.prompt, null);
      assert.ok(
        !fs.existsSync(f.ready),
        "the fake model must not start before matching owner acknowledgement",
      );
      assert.match(
        fs.readFileSync(receipt.paths.stderr, "utf8"),
        /supervisor.*(accept|identity)/,
      );
    } finally {
      await dispose(f);
    }
  }
});

test("trace write failure requests cancellation and retains an incomplete receipt", async () => {
  const f = fixture("hang"),
    write = fs.writeSync;
  let injected = false;
  fs.writeSync = function (fd, chunk, ...args) {
    if (!injected && String(chunk).includes("offline.partial")) {
      injected = true;
      throw Object.assign(new Error("controlled disk error"), { code: "EIO" });
    }
    return write.call(this, fd, chunk, ...args);
  };
  try {
    const { result, receipt, requested } = await controlled(f);
    assert.equal(injected, true);
    assert.equal(requested, true);
    assert.match(result.error, /jsonl_write_error: EIO/);
    assert.equal(receipt.completed_turns, 0);
    assert.equal(receipt.cleanup.owned_processes_gone, true);
  } finally {
    fs.writeSync = write;
    await dispose(f);
  }
});

test("expired work or a preexisting result refuses launch", async () => {
  const f = fixture();
  try {
    const work = process.env.EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC;
    process.env.EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC = "1";
    assert.match((await controlled(f)).result.error, /not started/);
    assert.deepEqual(fs.readdirSync(f.registry), []);
    assert.ok(!fs.existsSync(f.ready));
    process.env.EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC = work;
    fs.mkdirSync(f.manifest.resultsDir, { mode: 0o700 });
    const existing = path.join(f.manifest.resultsDir, "case-a.final.txt");
    fs.writeFileSync(existing, "previous evidence");
    await assert.rejects(controlled(f), /already exists/);
    assert.equal(fs.readFileSync(existing, "utf8"), "previous evidence");
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    await dispose(f);
  }
});

test("prompt cap and permissions follow the supplied manifest without exposing case labels", async () => {
  const f = fixture();
  try {
    const trial = f.manifest.cases[0];
    const built = buildInvocation(
      { ...f.manifest, trialMaxMs: 240000, serviceTier: "fast" },
      trial,
    );
    const retried = buildInvocation(
      { ...f.manifest, trialMaxMs: 600000 },
      trial,
    );
    assert.match(built.prompt, /hard cutoff of 4 minutes/);
    assert.match(retried.prompt, /hard cutoff of 10 minutes/);
    assert.ok(built.args.includes('service_tier="fast"'));
    assert.ok(!retried.args.some((arg) => arg.startsWith("service_tier=")));
    assert.ok(built.args.includes("features.fast_mode=false"));
    assert.ok(retried.args.includes("features.fast_mode=false"));
    for (const flag of [
      "allow_login_shell=false",
      "features.shell_snapshot=false",
      "agents.enabled=false",
      "features.multi_agent=false",
    ]) {
      assert.ok(built.args.includes(flag));
      assert.ok(retried.args.includes(flag));
    }
    assert.equal(built.profile.filesystem[f.manifest.denyPaths[0]], "deny");
    assert.equal(built.profile.filesystem[f.manifest.resultsDir], "deny");
    assert.equal(built.profile.filesystem[built.scratch], "write");
    assert.equal(built.profile.network.enabled, false);
    assert.equal(built.env.TMPDIR, built.scratch);
    assert.equal(built.shellEnv.TMPDIR, built.scratch);
    assert.ok(!JSON.stringify(built.args).includes(trial.id));
    assert.throws(
      () => buildInvocation(f.manifest, { ...trial, artifactStem: trial.id }),
      /opaque artifact stem/,
    );
  } finally {
    await dispose(f);
  }
});

test("Python PATH rejects relative selections that would search the reviewed repository", async () => {
  const f = fixture();
  try {
    for (const pythonPath of ["python3", "./python3", "", null]) {
      assert.throws(
        () =>
          buildInvocation({ ...f.manifest, pythonPath }, f.manifest.cases[0]),
        /pythonPath must be an absolute executable file/,
      );
    }
  } finally {
    await dispose(f);
  }
});

test("Python PATH requires an existing executable file", async () => {
  const f = fixture();
  try {
    const notExecutable = path.join(f.root, "not-executable-python");
    fs.writeFileSync(notExecutable, "#!/bin/sh\nexit 0\n", { mode: 0o600 });
    for (const pythonPath of [
      notExecutable,
      f.root,
      path.join(f.root, "missing-python"),
    ]) {
      assert.throws(
        () =>
          buildInvocation({ ...f.manifest, pythonPath }, f.manifest.cases[0]),
        /pythonPath must be an absolute executable file/,
      );
    }
    const selected = fs.realpathSync(python.executable);
    const built = buildInvocation(
      { ...f.manifest, pythonPath: selected },
      f.manifest.cases[0],
    );
    assert.equal(
      built.env.PATH.split(path.delimiter)[0],
      path.dirname(selected),
    );
  } finally {
    await dispose(f);
  }
});

test("Python command identity rejects missing and different python3 aliases", async (t) => {
  for (const alias of ["missing", "different"])
    await t.test(alias, async () => {
      const f = fixture();
      try {
        const bin = path.join(f.root, "selected-python");
        fs.mkdirSync(bin);
        const selected = path.join(bin, "python");
        fs.symlinkSync(python.executable, selected);
        if (alias === "different")
          fs.symlinkSync("/bin/sh", path.join(bin, "python3"));
        assert.throws(
          () =>
            buildInvocation(
              { ...f.manifest, pythonPath: selected },
              f.manifest.cases[0],
            ),
          /python3 must resolve to pythonPath/,
        );
        assert.equal(
          fs.existsSync(f.gitRequests),
          false,
          "Reject interpreter mismatch before Git execution",
        );
      } finally {
        await dispose(f);
      }
    });
});

test("Python command identity accepts a matching alias without extra grants", async () => {
  const f = fixture();
  try {
    const bin = path.join(f.root, "selected-python");
    fs.mkdirSync(bin);
    const selected = path.join(bin, "python");
    fs.symlinkSync(python.executable, selected);
    fs.symlinkSync(selected, path.join(bin, "python3"));
    const before = buildInvocation(f.manifest, f.manifest.cases[0]);
    const built = buildInvocation(
      { ...f.manifest, pythonPath: selected },
      f.manifest.cases[0],
    );
    assert.deepEqual(built.profile, before.profile);
    const actual = spawnSync(
      "/bin/sh",
      ["-c", "python3 -c 'import sys; print(sys.executable)'"],
      { cwd: built.repo, env: built.shellEnv, encoding: "utf8", timeout: 5000 },
    );
    assert.equal(actual.status, 0, actual.stderr);
    assert.equal(
      fs.realpathSync(actual.stdout.trim()),
      fs.realpathSync(selected),
    );
  } finally {
    await dispose(f);
  }
});

test("Pinned tool digests reject each changed executable before Git execution", async (t) => {
  const f = fixture();
  try {
    const bin = path.join(f.root, "pinned-tools");
    fs.mkdirSync(bin);
    for (const [field, name] of [
      ["nodePath", "node"],
      ["rgPath", "rg"],
      ["pythonPath", "python3"],
    ]) {
      f.manifest[field] = path.join(bin, name);
      fs.writeFileSync(f.manifest[field], "#!/bin/sh\nexit 0\n", {
        mode: 0o700,
      });
    }
    const fields = ["codexPath", "nodePath", "gitPath", "rgPath", "pythonPath"];
    f.manifest.toolSha256 = Object.fromEntries(
      fields.map((field) => [
        field,
        createHash("sha256")
          .update(fs.readFileSync(f.manifest[field]))
          .digest("hex"),
      ]),
    );
    buildInvocation(f.manifest, f.manifest.cases[0]);
    for (const field of fields)
      await t.test(field, () => {
        const original = fs.readFileSync(f.manifest[field]);
        fs.rmSync(f.gitRequests, { force: true });
        fs.appendFileSync(
          f.manifest[field],
          "\n# replaced after preparation\n",
        );
        try {
          assert.throws(
            () => buildInvocation(f.manifest, f.manifest.cases[0]),
            new RegExp(`Tool SHA-256 mismatch: ${field}`),
          );
          assert.equal(
            fs.existsSync(f.gitRequests),
            false,
            "No selected Git may run before digest checks",
          );
        } finally {
          fs.writeFileSync(f.manifest[field], original);
        }
      });
  } finally {
    await dispose(f);
  }
});

test("Pinned tool digests require a complete valid map when supplied", async () => {
  const f = fixture();
  try {
    const pins = Object.fromEntries(
      ["codexPath", "nodePath", "gitPath"].map((field) => [
        field,
        createHash("sha256")
          .update(fs.readFileSync(f.manifest[field]))
          .digest("hex"),
      ]),
    );
    for (const toolSha256 of [
      null,
      [],
      {},
      { ...pins, gitPath: "invalid" },
      { ...pins, unexpected: "a".repeat(64) },
    ]) {
      assert.throws(
        () =>
          buildInvocation({ ...f.manifest, toolSha256 }, f.manifest.cases[0]),
        /Invalid toolSha256 map/,
      );
    }
    assert.equal(fs.existsSync(f.gitRequests), false);
  } finally {
    await dispose(f);
  }
});

test("Python selection and Zsh here-documents use the exact scratch environment", async (t) => {
  const zsh = ["/bin/zsh", "/usr/bin/zsh"].find((value) =>
    fs.existsSync(value),
  );
  if (!zsh) {
    t.skip("Zsh is not installed on this host");
    return;
  }
  const f = fixture();
  try {
    const selected = fs.realpathSync(
      process.platform === "darwin"
        ? "/Library/Developer/CommandLineTools/usr/bin/python3"
        : python.executable,
    );
    f.manifest.pythonPath = selected;
    const before = buildInvocation(
      { ...f.manifest, pythonPath: undefined },
      f.manifest.cases[0],
    );
    const built = buildInvocation(f.manifest, f.manifest.cases[0]);
    assert.deepEqual(
      built.profile,
      before.profile,
      "Python PATH selection must not add filesystem grants",
    );
    assert.equal(
      built.env.PATH.split(path.delimiter)[0],
      path.dirname(selected),
    );
    assert.equal(built.env.TMPPREFIX, path.join(built.scratch, "zsh"));
    assert.equal(built.shellEnv.TMPPREFIX, built.env.TMPPREFIX);
    assert.equal(built.shellEnv.PATH, built.env.PATH);
    const setting = built.args.find((arg) =>
      arg.startsWith("shell_environment_policy.set="),
    );
    assert.ok(
      setting.includes(`TMPPREFIX=${JSON.stringify(built.env.TMPPREFIX)}`),
    );
    fs.mkdirSync(built.scratch, { recursive: true, mode: 0o700 });
    const script = `python3 - <<'PY'\nimport json, os, pathlib, sys\np = pathlib.Path(os.environ["TMPDIR"]) / "heredoc.txt"\np.write_text("scratch write passed")\nprint(json.dumps({"python": sys.executable, "prefix": os.environ["TMPPREFIX"], "value": p.read_text()}))\nPY\n`;
    const run = spawnSync(zsh, ["-f", "-c", script], {
      cwd: built.repo,
      env: { ...built.env, ...built.shellEnv },
      encoding: "utf8",
      timeout: 5000,
    });
    assert.equal(run.status, 0, run.stderr);
    const result = JSON.parse(run.stdout);
    assert.equal(fs.realpathSync(result.python), selected);
    assert.equal(result.prefix, path.join(built.scratch, "zsh"));
    assert.equal(result.value, "scratch write passed");
  } finally {
    await dispose(f);
  }
});

test("real supervisor and provider agree on completion, abort, and timeout evidence", async () => {
  const supervisor = fileURLToPath(
    new URL("../../scripts/run_campaign.py", import.meta.url),
  );
  const providerPath = fileURLToPath(
    new URL("./codex-review-provider.cjs", import.meta.url),
  );
  for (const mode of ["success", "abort", "timeout"]) {
    const f = fixture(mode === "success" ? "success" : "hang", {
      trialMaxMs: 1500,
    });
    const resultPath = path.join(f.root, "provider-result.json");
    const runner = path.join(f.root, "framework.cjs");
    fs.writeFileSync(
      runner,
      `const fs=require('node:fs');const Provider=require(${JSON.stringify(providerPath)});
const abort=new AbortController();
const poll=${JSON.stringify(mode)}==='abort' && setInterval(()=>{if(fs.existsSync(${JSON.stringify(f.ready)}))abort.abort();},10);
new Provider({config:{manifest:${JSON.stringify(path.join(f.root, "manifest.json"))}}})
 .callApi(${JSON.stringify(f.manifest.cases[0].prompt)},{vars:{case_id:'original-pr',input:${JSON.stringify(f.manifest.cases[0].prompt)}}},{abortSignal:abort.signal})
 .then(result=>fs.writeFileSync(${JSON.stringify(resultPath)},JSON.stringify(result)))
 .finally(()=>clearInterval(poll));\n`,
    );
    try {
      const execution = spawnSync(
        python.executable,
        [
          supervisor,
          "--seconds",
          "8",
          "--cleanup-seconds",
          "2",
          "--trial-max-ms",
          "1500",
          "--registry",
          f.registry,
          "--",
          process.execPath,
          runner,
        ],
        { encoding: "utf8", timeout: 10000 },
      );
      const campaignPath = path.join(f.root, "campaign-receipt.json");
      assert.equal(
        execution.status,
        0,
        execution.stderr ||
          execution.stdout ||
          execution.error?.message ||
          (fs.existsSync(campaignPath) &&
            fs.readFileSync(campaignPath, "utf8")),
      );
      const result = JSON.parse(fs.readFileSync(resultPath));
      const receipt = JSON.parse(fs.readFileSync(result.metadata.receipt));
      const campaign = JSON.parse(fs.readFileSync(campaignPath));
      assert.equal(campaign.cleanup_verified, true);
      assert.deepEqual(campaign.errors, []);
      assert.equal(receipt.cleanup.owned_processes_gone, true);
      assert.equal(receipt.trace_complete, true);
      if (mode === "success") {
        assert.equal(result.error, undefined);
        assert.ok(JSON.parse(result.output).supervisorEnvAbsent);
        assert.deepEqual(receipt.original_usage, {
          input_tokens: 31,
          cached_input_tokens: 7,
          output_tokens: 11,
        });
        assert.equal(receipt.cleanup.reason, "root_exit");
      } else {
        assert.equal(
          result.error,
          mode === "abort" ? "aborted" : "trial_or_campaign_deadline",
        );
        assert.equal(
          receipt.cleanup.reason,
          mode === "abort" ? "provider_abort" : "trial_deadline",
        );
        assert.match(
          fs.readFileSync(receipt.paths.jsonl, "utf8"),
          /preserve this prefix/,
        );
        assert.equal(receipt.completed_turns, 0);
        assert.equal(receipt.usage.prompt, null);
      }
    } finally {
      fs.writeFileSync(f.stop, "fixture cleanup");
      await dispose(f);
    }
  }
});

test("regression: every permission grant rejects hidden evidence and its aliases before launch", async (t) => {
  const checks = {
    "runtime results path": (f) => {
      f.manifest.runtimeReadPaths = [f.manifest.resultsDir];
    },
    "normalized denied path": (f) => {
      f.manifest.runtimeReadPaths = [f.manifest.denyPaths[0] + "/nested/.."];
    },
    "runtime descendant of denied path": (f) => {
      f.manifest.runtimeReadPaths = [
        path.join(f.manifest.denyPaths[0], "answers.json"),
      ];
    },
    "case repository": (f) => {
      f.manifest.denyPaths.push(f.manifest.cases[0].repo);
    },
    "review skill directory": (f) => {
      f.manifest.denyPaths.push(path.dirname(f.manifest.skillEntry));
    },
    "test-audit directory": (f) => {
      f.manifest.denyPaths.push(
        path.join(f.manifest.runtimeRoot, "test-audit"),
      );
    },
    "scratch write directory": (f) => {
      const scratch = path.join(f.manifest.cases[0].repo, ".eval-tmp");
      fs.mkdirSync(scratch);
      f.manifest.denyPaths.push(scratch);
    },
    "another case repository": (f) => {
      const sibling = path.join(f.root, "other-case");
      fs.mkdirSync(sibling);
      f.manifest.cases.push({
        ...f.manifest.cases[0],
        id: "other-pr",
        artifactStem: "case-b",
        repo: sibling,
      });
      f.manifest.runtimeReadPaths = [sibling];
    },
    "symlink to missing results descendant": (f) => {
      const alias = path.join(f.root, "alias");
      fs.symlinkSync(f.root, alias);
      f.manifest.runtimeReadPaths = [
        path.join(alias, "results/new/evidence.json"),
      ];
    },
    "denied symlink alias": (f) => {
      const alias = path.join(f.root, "alias");
      fs.symlinkSync(f.manifest.denyPaths[0], alias);
      f.manifest.denyPaths = [alias];
      f.manifest.runtimeReadPaths = [path.join(f.root, "private")];
    },
    "hard-linked hidden file": (f) => {
      const hidden = path.join(f.root, "answer.txt"),
        alias = path.join(f.root, "alias.txt");
      fs.writeFileSync(hidden, "hidden answer");
      fs.linkSync(hidden, alias);
      f.manifest.denyPaths.push(hidden);
      f.manifest.runtimeReadPaths = [alias];
    },
    "special permission alias": (f) => {
      f.manifest.runtimeReadPaths = [":root"];
    },
    "prior repeat scratch grant": (f) => {
      f.manifest.runtimeReadPaths = [
        path.join(f.manifest.cases[0].repo, ".eval-tmp/repeat-2"),
      ];
    },
  };
  for (const [name, configure] of Object.entries(checks))
    await t.test(name, async () => {
      const f = fixture();
      try {
        configure(f);
        f.provider.manifest = f.manifest;
        await assert.rejects(
          controlled(f),
          /Permission grant exposes denied evidence|Permission grant exposes prior scratch|absolute filesystem paths/,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
      } finally {
        await dispose(f);
      }
    });
});

test("regression: a broad read preserves narrower denies and component boundaries", async () => {
  const f = fixture();
  try {
    const sibling = path.join(f.root, "private-tools");
    fs.mkdirSync(sibling);
    f.manifest.runtimeReadPaths = [f.root, sibling];
    const built = buildInvocation(f.manifest, f.manifest.cases[0]);
    assert.equal(built.profile.filesystem[f.root], "read");
    assert.equal(built.profile.filesystem[sibling], "read");
    assert.equal(built.profile.filesystem[f.manifest.denyPaths[0]], "deny");
    assert.equal(built.profile.filesystem[f.manifest.resultsDir], "deny");
  } finally {
    await dispose(f);
  }
});

test("regression: Promptfoo repeats preserve distinct evidence and the unchanged case identity", async () => {
  const f = fixture();
  try {
    const first = await controlled(f);
    const firstScratch = JSON.parse(first.result.output).scratch;
    const scratchMarker = path.join(firstScratch, "prior-check.txt");
    fs.writeFileSync(scratchMarker, "prior disposable check");
    const originalBytes = Object.fromEntries(
      Object.entries(first.receipt.paths).map(([key, file]) => [
        key,
        fs.readFileSync(file),
      ]),
    );
    const second = await controlled(
      f,
      {},
      {},
      { vars: { case_id: "original-pr" }, repeatIndex: 1 },
    );
    assert.equal(first.result.error, undefined);
    assert.equal(second.result.error, undefined);
    for (const [key, file] of Object.entries(first.receipt.paths)) {
      assert.deepEqual(fs.readFileSync(file), originalBytes[key]);
      assert.notEqual(file, second.receipt.paths[key]);
      assert.ok(fs.existsSync(second.receipt.paths[key]));
    }
    assert.equal(path.basename(first.receipt.paths.jsonl), "case-a.jsonl");
    assert.equal(
      path.basename(second.receipt.paths.jsonl),
      "case-a.repeat-1.jsonl",
    );
    assert.equal(first.receipt.repeat_index, 0);
    assert.equal(second.receipt.repeat_index, 1);
    assert.equal(first.result.metadata.repeatIndex, 0);
    assert.equal(second.result.metadata.repeatIndex, 1);
    assert.equal(second.registration.case_id, first.registration.case_id);
    assert.notEqual(second.registration.pid, first.registration.pid);
    assert.notEqual(
      second.registration.registration_id,
      first.registration.registration_id,
    );
    assert.equal(
      second.receipt.registration_id,
      second.registration.registration_id,
    );
    const secondScratch = JSON.parse(second.result.output).scratch;
    assert.notEqual(firstScratch, secondScratch);
    assert.equal(
      second.receipt.permission_profile.filesystem[path.dirname(firstScratch)],
      "deny",
    );
    assert.equal(
      second.receipt.permission_profile.filesystem[firstScratch],
      undefined,
    );
    assert.equal(
      second.receipt.permission_profile.filesystem[secondScratch],
      "write",
    );
    assert.equal(
      fs.readFileSync(scratchMarker, "utf8"),
      "prior disposable check",
    );
    assert.equal(
      second.receipt.prompt.replaceAll(secondScratch, firstScratch),
      first.receipt.prompt,
    );
    assert.deepEqual(
      second.receipt.original_usage,
      first.receipt.original_usage,
    );
  } finally {
    await dispose(f);
  }
});

test("regression: a leftover repeat scratch directory refuses launch and preserves its contents", async () => {
  const f = fixture();
  try {
    const scratch = path.join(
      f.manifest.cases[0].repo,
      ".eval-tmp",
      "repeat-0",
    );
    fs.mkdirSync(scratch, { recursive: true });
    const marker = path.join(scratch, "notes");
    fs.writeFileSync(marker, "previous attempt");
    await assert.rejects(controlled(f), /EEXIST/);
    assert.equal(fs.readFileSync(marker, "utf8"), "previous attempt");
    assert.deepEqual(fs.readdirSync(f.registry), []);
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    await dispose(f);
  }
});

test("regression: a symlink scratch root refuses launch without writing outside the case", async () => {
  const f = fixture();
  try {
    const outside = path.join(f.root, "outside");
    fs.mkdirSync(outside);
    fs.symlinkSync(outside, path.join(f.manifest.cases[0].repo, ".eval-tmp"));
    await assert.rejects(controlled(f), /Scratch root must not be a symlink/);
    assert.deepEqual(fs.readdirSync(outside), []);
    assert.deepEqual(fs.readdirSync(f.registry), []);
    assert.ok(!fs.existsSync(f.ready));
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
  } finally {
    await dispose(f);
  }
});

test("regression: invalid repeat identities and shim-incompatible case IDs fail before launch", async (t) => {
  const invalidRepeats = [
    -1,
    0.5,
    "1",
    null,
    NaN,
    Infinity,
    Number.MAX_SAFE_INTEGER + 1,
  ];
  const invalidIds = [
    "-case",
    ".case",
    "_case",
    "a".repeat(81),
    "case\n",
    "case\r",
    "case/a",
    7,
  ];
  for (const repeatIndex of invalidRepeats)
    await t.test(`repeat ${String(repeatIndex)}`, async () => {
      const f = fixture();
      try {
        await assert.rejects(
          controlled(
            f,
            {},
            {},
            { vars: { case_id: "original-pr" }, repeatIndex },
          ),
          /Invalid repeatIndex/,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        await dispose(f);
      }
    });
  for (const id of invalidIds)
    await t.test(`case ${JSON.stringify(id)}`, async () => {
      const f = fixture();
      try {
        // Build preflight directly: the old bug otherwise waits the entire shared
        // deadline for a registration the shim correctly refuses to create.
        assert.throws(
          () => buildInvocation(f.manifest, { ...f.manifest.cases[0], id }),
          /Unsafe case id/,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        await dispose(f);
      }
    });
});

test("regression: shim-compatible case IDs reach the model without entering its prompt", async () => {
  const f = fixture();
  try {
    const id = "Review_01.original-" + "a".repeat(61);
    assert.equal(id.length, 80);
    f.provider.manifest.cases[0].id = id;
    const { result, registration } = await controlled(
      f,
      {},
      {},
      { vars: { case_id: id } },
    );
    assert.equal(result.error, undefined);
    assert.equal(registration.case_id, id);
    assert.ok(!JSON.parse(result.output).prompt.includes(id));
  } finally {
    await dispose(f);
  }
});

test("round2: missing or non-directory case repositories fail before any output or launch", async (t) => {
  for (const mode of ["missing", "file"])
    await t.test(mode, async () => {
      const f = fixture();
      const repo = f.manifest.cases[0].repo;
      try {
        fs.rmSync(repo, { recursive: true });
        if (mode === "file")
          fs.writeFileSync(repo, "a file is not a repository directory");
        await assert.rejects(
          controlled(f),
          /Case repository must be an existing directory/,
        );
        assert.equal(fs.existsSync(repo), mode === "file");
        if (mode === "file")
          assert.equal(
            fs.readFileSync(repo, "utf8"),
            "a file is not a repository directory",
          );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        await dispose(f);
      }
    });
});

test("round2: output pipe errors request cancellation and preserve incomplete evidence", async (t) => {
  for (const stream of ["stdout", "stderr"])
    await t.test(stream, async () => {
      const f = fixture("hang"),
        emit = ChildProcess.prototype.emit;
      let injected = false,
        unhandled;
      ChildProcess.prototype.emit = function (event, ...args) {
        if (event === "spawn")
          this.stdout.once("data", () => {
            injected = true;
            // Catch only the test injection's unhandled EventEmitter throw. This
            // makes the old provider fail without crashing the test runner or
            // stranding its fixture; normal production would terminate Node.
            try {
              this[stream].emit(
                "error",
                Object.assign(new Error("controlled pipe failure"), {
                  code: "EIO",
                }),
              );
            } catch (error) {
              unhandled = error;
              fs.writeFileSync(
                f.stop,
                "fixture cleanup after unhandled stream error",
              );
            }
          });
        return emit.call(this, event, ...args);
      };
      try {
        const { result, receipt, requested } = await controlled(f);
        assert.equal(injected, true);
        assert.equal(
          unhandled,
          undefined,
          "output pipe error must have a handler",
        );
        assert.equal(requested, true);
        assert.equal(result.error, `${stream}_read_error: EIO`);
        assert.equal(receipt.error, result.error);
        assert.equal(receipt.trace_complete, false);
        assert.equal(receipt.cleanup.owned_processes_gone, true);
        assert.equal(receipt.cleanup.reason, "provider_abort");
        assert.match(
          fs.readFileSync(receipt.paths.jsonl, "utf8"),
          /preserve this prefix/,
        );
        assert.deepEqual(
          [
            receipt.usage.prompt,
            receipt.usage.cached,
            receipt.usage.completion,
          ],
          [null, null, null],
        );
      } finally {
        ChildProcess.prototype.emit = emit;
        await dispose(f);
      }
    });
});

test("round3: incomplete review ranges and prompts fail when loading the manifest", async (t) => {
  for (const field of ["base", "head", "prompt"]) {
    for (const value of [undefined, "", " \n ", null, 17, {}])
      await t.test(`${field} ${JSON.stringify(value)}`, async () => {
        const f = fixture();
        try {
          f.manifest.cases[0][field] = value;
          const file = path.join(f.root, "invalid-manifest.json");
          fs.writeFileSync(file, JSON.stringify(f.manifest));
          assert.throws(
            () => new Provider({ config: { manifest: file } }),
            /must be a non-empty string/,
          );
          assert.ok(!fs.existsSync(f.manifest.resultsDir));
          assert.deepEqual(fs.readdirSync(f.registry), []);
        } finally {
          await dispose(f);
        }
      });
  }
});

test("round3: duplicate case IDs fail at load and before routing a modified manifest", async () => {
  const f = fixture();
  try {
    f.manifest.cases.push({
      ...f.manifest.cases[0],
      repo: path.join(f.root, "different-repo"),
      prompt: "A different requested review.",
    });
    const file = path.join(f.root, "duplicate-manifest.json");
    fs.writeFileSync(file, JSON.stringify(f.manifest));
    assert.throws(
      () => new Provider({ config: { manifest: file } }),
      /Duplicate case id/,
    );
    f.provider.manifest = f.manifest;
    await assert.rejects(controlled(f), /Duplicate case id/);
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
    assert.deepEqual(fs.readdirSync(f.registry), []);
  } finally {
    await dispose(f);
  }
});

test("round3: unsafe result permissions refuse artifact creation", async (t) => {
  for (const mode of [0o777, 0o770, 0o755, 0o500])
    await t.test(mode.toString(8), async () => {
      const f = fixture();
      try {
        fs.mkdirSync(f.manifest.resultsDir);
        fs.chmodSync(f.manifest.resultsDir, mode);
        await assert.rejects(
          controlled(f),
          /Results directory must be user-owned with mode 0700/,
        );
        assert.equal(fs.statSync(f.manifest.resultsDir).mode & 0o777, mode);
        assert.deepEqual(fs.readdirSync(f.manifest.resultsDir), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        fs.chmodSync(f.manifest.resultsDir, 0o700);
        await dispose(f);
      }
    });
});

test("round3: result paths reject untrusted ancestors and leaf symlinks", async (t) => {
  for (const mode of ["writable-parent", "leaf-symlink"])
    await t.test(mode, async () => {
      const f = fixture();
      try {
        if (mode === "writable-parent") {
          const parent = path.join(f.root, "untrusted");
          fs.mkdirSync(parent);
          fs.chmodSync(parent, 0o777);
          f.provider.manifest.resultsDir = path.join(parent, "results");
        } else {
          const target = path.join(f.root, "target");
          fs.mkdirSync(target, { mode: 0o700 });
          fs.symlinkSync(target, f.manifest.resultsDir);
        }
        await assert.rejects(
          controlled(f),
          /Untrusted results ancestor|Results directory must not be a symlink/,
        );
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
});

test("round3: result directory ownership is checked before reserving artifacts", async () => {
  const f = fixture(),
    stat = fs.statSync;
  try {
    fs.mkdirSync(f.manifest.resultsDir, { mode: 0o700 });
    fs.statSync = function (value, ...args) {
      const info = stat.call(this, value, ...args);
      if (value === f.manifest.resultsDir) info.uid = process.geteuid() + 1;
      return info;
    };
    await assert.rejects(
      controlled(f),
      /Results directory must be user-owned with mode 0700/,
    );
    assert.deepEqual(fs.readdirSync(f.manifest.resultsDir), []);
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    fs.statSync = stat;
    await dispose(f);
  }
});

test("round3: trusted private results retain canonical output paths and allow fresh nested parents", async () => {
  const f = fixture();
  try {
    const alias = path.join(f.root, "parent-alias");
    fs.symlinkSync(f.root, alias);
    f.provider.manifest.resultsDir = path.join(alias, "fresh/private/results");
    const { result, receipt } = await controlled(f);
    assert.equal(result.error, undefined);
    assert.equal(
      fs.statSync(path.dirname(result.metadata.receipt)).mode & 0o777,
      0o700,
    );
    for (const output of Object.values(receipt.paths)) {
      assert.ok(
        output.startsWith(
          path.join(f.root, "fresh/private/results") + path.sep,
        ),
      );
      assert.ok(fs.existsSync(output));
    }
  } finally {
    await dispose(f);
  }
});

test("round3: hidden evidence metadata rejects shared regular files through nested directories and symlink targets", async (t) => {
  for (const kind of ["nested", "symlink-target"])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const hidden = f.manifest.denyPaths[0];
        fs.mkdirSync(hidden, { recursive: true });
        const target = path.join(f.root, "metadata-only-fixture");
        fs.mkdirSync(target);
        const emptyFile = path.join(target, "empty");
        fs.writeFileSync(emptyFile, "");
        fs.linkSync(emptyFile, path.join(target, "same-empty-file"));
        if (kind === "nested") f.manifest.denyPaths = [target];
        else fs.symlinkSync(target, path.join(hidden, "directory-target"));
        // Both names stay in the metadata-only hidden fixture. No granted path
        // receives an alias, and no model or sandbox reads file contents.
        assert.throws(
          () => buildInvocation(f.manifest, f.manifest.cases[0]),
          kind === "nested"
            ? /Hidden evidence must use independent regular files/
            : /Hidden evidence must not contain symlinks/,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        await dispose(f);
      }
    });
});

test("round3: independent hidden copies and unrelated runtime hard links remain allowed", async () => {
  const f = fixture();
  try {
    fs.mkdirSync(f.manifest.denyPaths[0], { recursive: true });
    fs.writeFileSync(path.join(f.manifest.denyPaths[0], "one"), "");
    fs.writeFileSync(path.join(f.manifest.denyPaths[0], "two"), "");
    const runtime = path.join(f.root, "verified-runtime");
    fs.mkdirSync(runtime);
    const file = path.join(runtime, "tool-data");
    fs.writeFileSync(file, "");
    fs.linkSync(file, path.join(runtime, "tool-data-link"));
    f.manifest.runtimeReadPaths = [runtime];
    const built = buildInvocation(f.manifest, f.manifest.cases[0]);
    assert.equal(built.profile.filesystem[runtime], "read");
    assert.equal(built.profile.filesystem[f.manifest.denyPaths[0]], "deny");
  } finally {
    await dispose(f);
  }
});

test("round3: hidden evidence inspection fails closed on an unreadable directory", async () => {
  const f = fixture(),
    open = fs.opendirSync;
  try {
    fs.mkdirSync(f.manifest.denyPaths[0], { recursive: true });
    fs.opendirSync = function (value, ...args) {
      if (value === f.manifest.denyPaths[0])
        throw Object.assign(new Error("controlled metadata access failure"), {
          code: "EACCES",
        });
      return open.call(this, value, ...args);
    };
    assert.throws(
      () => buildInvocation(f.manifest, f.manifest.cases[0]),
      /controlled metadata access failure/,
    );
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    fs.opendirSync = open;
    await dispose(f);
  }
});

test("round3: oversized hidden inventories fail closed and close the directory handle", async () => {
  const f = fixture(),
    open = fs.opendirSync;
  let reads = 0,
    closed = false;
  try {
    fs.mkdirSync(f.manifest.denyPaths[0], { recursive: true });
    fs.opendirSync = function (value, ...args) {
      if (value === f.manifest.denyPaths[0])
        return {
          readSync() {
            return ++reads <= 10001
              ? { name: `metadata-entry-${reads}` }
              : null;
          },
          closeSync() {
            closed = true;
          },
        };
      return open.call(this, value, ...args);
    };
    assert.throws(
      () => buildInvocation(f.manifest, f.manifest.cases[0]),
      /bounded metadata limit/,
    );
    assert.ok(reads > 0 && reads <= 10001);
    assert.equal(closed, true);
    assert.ok(!fs.existsSync(f.ready));
    assert.deepEqual(fs.readdirSync(f.registry), []);
  } finally {
    fs.opendirSync = open;
    await dispose(f);
  }
});

test("round4: nested hidden symlinks fail closed using metadata only", async (t) => {
  for (const kind of ["file", "directory", "dangling"])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const hidden = f.manifest.denyPaths[0];
        fs.mkdirSync(hidden, { recursive: true });
        const target = path.join(f.root, "empty-target");
        if (kind === "file") fs.writeFileSync(target, "");
        if (kind === "directory") fs.mkdirSync(target);
        fs.symlinkSync(target, path.join(hidden, "nested-link"));
        // Inert metadata fixtures only. No target is granted or opened for reading.
        assert.throws(
          () => buildInvocation(f.manifest, f.manifest.cases[0]),
          /Hidden evidence must not contain symlinks/,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
      } finally {
        await dispose(f);
      }
    });
});

test("round4: canonical top-level deny aliases remain supported and dangling roots refuse", async () => {
  const f = fixture();
  try {
    const hidden = f.manifest.denyPaths[0];
    fs.mkdirSync(hidden, { recursive: true });
    fs.writeFileSync(path.join(hidden, "empty"), "");
    const alias = path.join(f.root, "deny-alias");
    fs.symlinkSync(hidden, alias);
    f.manifest.denyPaths = [alias];
    const built = buildInvocation(f.manifest, f.manifest.cases[0]);
    assert.equal(built.profile.filesystem[hidden], "deny");
    assert.equal(built.profile.filesystem[alias], undefined);
    fs.unlinkSync(alias);
    fs.symlinkSync(path.join(f.root, "absent"), alias);
    assert.throws(
      () => buildInvocation(f.manifest, f.manifest.cases[0]),
      /Unresolved permission path symlink/,
    );
  } finally {
    await dispose(f);
  }
});

test("round4: all artifact stems must be well-formed and unique before selecting a case", async (t) => {
  for (const stem of [
    "case-a",
    undefined,
    "",
    "case-B",
    "../case-b",
    "case-b\n",
  ])
    await t.test(String(stem), async () => {
      const f = fixture();
      try {
        f.manifest.cases.push({
          ...f.manifest.cases[0],
          id: "second-pr",
          artifactStem: stem,
        });
        const file = path.join(f.root, "invalid-stems.json");
        fs.writeFileSync(file, JSON.stringify(f.manifest));
        const expected =
          stem === "case-a"
            ? /Duplicate artifact stem/
            : /opaque artifact stem/;
        assert.throws(
          () => new Provider({ config: { manifest: file } }),
          expected,
        );
        f.provider.manifest = f.manifest;
        await assert.rejects(
          f.provider.callApi("", { vars: { case_id: "original-pr" } }),
          expected,
        );
        assert.throws(
          () => buildInvocation(f.manifest, f.manifest.cases[0]),
          expected,
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
      } finally {
        await dispose(f);
      }
    });
});

test("round4: duplicate case IDs take precedence over malformed or duplicate stems", async () => {
  const f = fixture();
  try {
    f.manifest.cases[0].artifactStem = "invalid";
    f.manifest.cases.push({ ...f.manifest.cases[0] });
    assert.throws(
      () => buildInvocation(f.manifest, f.manifest.cases[0]),
      /Duplicate case id/,
    );
  } finally {
    await dispose(f);
  }
});

test("round4: distinct valid stems produce separate paths for every case and repeat", async () => {
  const f = fixture();
  try {
    const sibling = path.join(f.root, "repo-b");
    createFixtureRepo(sibling);
    f.manifest.cases.push({
      ...f.manifest.cases[0],
      id: "second-pr",
      artifactStem: "case-b",
      repo: sibling,
    });
    const file = path.join(f.root, "valid-stems.json");
    fs.writeFileSync(file, JSON.stringify(f.manifest));
    assert.doesNotThrow(() => new Provider({ config: { manifest: file } }));
    const outputs = f.manifest.cases.flatMap((trial) =>
      [0, 1].flatMap((repeat) =>
        Object.values(buildInvocation(f.manifest, trial, repeat).paths),
      ),
    );
    assert.equal(outputs.length, 16);
    assert.equal(new Set(outputs).size, outputs.length);
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
    assert.deepEqual(fs.readdirSync(f.registry), []);
  } finally {
    await dispose(f);
  }
});

test("round5: explicit hidden roots and sibling repositories must exist before launch", async (t) => {
  for (const kind of ["hidden-root", "sibling-repo"])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const absent = path.join(f.root, "absent");
        if (kind === "hidden-root") f.manifest.denyPaths = [absent];
        else
          f.manifest.cases.push({
            ...f.manifest.cases[0],
            id: "sibling",
            artifactStem: "case-b",
            repo: absent,
          });
        f.provider.manifest = f.manifest;
        await assert.rejects(
          controlled(f),
          /Hidden evidence path does not exist|Case repository must be an existing directory/,
        );
        assert.ok(!fs.existsSync(absent));
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(
          !fs.existsSync(path.join(f.manifest.cases[0].repo, ".eval-tmp")),
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        assert.ok(!fs.existsSync(f.ready));
      } finally {
        await dispose(f);
      }
    });
});

test("round5: both frozen skills must be readable regular files before launch", async (t) => {
  for (const skill of ["review", "test-audit"])
    for (const state of ["missing", "directory", "unreadable", "symlink"]) {
      await t.test(`${skill} ${state}`, async () => {
        const f = fixture();
        const entry =
          skill === "review"
            ? f.manifest.skillEntry
            : path.join(f.manifest.runtimeRoot, "test-audit/SKILL.md");
        try {
          if (state === "unreadable") fs.chmodSync(entry, 0);
          else {
            fs.unlinkSync(entry);
            if (state === "directory") fs.mkdirSync(entry);
            if (state === "symlink") {
              const target = path.join(f.root, "other-skill.md");
              fs.writeFileSync(target, "# An inert file\n");
              fs.symlinkSync(target, entry);
            }
          }
          await assert.rejects(
            controlled(f),
            /Frozen skill entry must be a readable regular file/,
          );
          assert.ok(!fs.existsSync(f.manifest.resultsDir));
          assert.ok(
            !fs.existsSync(path.join(f.manifest.cases[0].repo, ".eval-tmp")),
          );
          assert.deepEqual(fs.readdirSync(f.registry), []);
          assert.ok(!fs.existsSync(f.ready));
        } finally {
          if (state === "unreadable") fs.chmodSync(entry, 0o600);
          await dispose(f);
        }
      });
    }
  await t.test(
    "canonical parent aliases preserve readable entries",
    async () => {
      const f = fixture();
      try {
        const alias = path.join(f.root, "runtime-alias");
        fs.symlinkSync(f.manifest.runtimeRoot, alias);
        f.provider.manifest.runtimeRoot = alias;
        f.provider.manifest.skillEntry = path.join(alias, "review/SKILL.md");
        assert.equal((await controlled(f)).result.error, undefined);
      } finally {
        await dispose(f);
      }
    },
  );
});

test("round5: rendered input and exported vars must both match the frozen case", async (t) => {
  for (const kind of ["rendered", "vars", "missing-vars"])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const controller =
          kind === "rendered"
            ? { renderedPrompt: "A stale review request." }
            : {};
        const context = {
          vars: {
            case_id: "original-pr",
            input:
              kind === "missing-vars"
                ? undefined
                : kind === "vars"
                  ? "A stale review request."
                  : f.manifest.cases[0].prompt,
          },
        };
        const { result } = await controlled(f, {}, controller, context);
        assert.match(
          result.error || "",
          /Promptfoo input does not match the frozen case prompt/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
  await t.test("matching input preserves its exact digest", async () => {
    const f = fixture();
    try {
      f.provider.manifest.cases[0].prompt = "Review this change.\nUnicode: €\n";
      const { result, receipt } = await controlled(f);
      assert.equal(result.error, undefined);
      const digest = createHash("sha256")
        .update(f.provider.manifest.cases[0].prompt)
        .digest("hex");
      assert.equal(receipt.input_sha256, digest);
      assert.equal(result.metadata.input_sha256, digest);
      assert.ok(
        JSON.parse(result.output).prompt.endsWith(
          f.provider.manifest.cases[0].prompt,
        ),
      );
    } finally {
      await dispose(f);
    }
  });
});

test("round5: short writes to either trace make completion and usage incomplete", async (t) => {
  for (const stream of ["jsonl", "stderr"])
    await t.test(stream, async () => {
      const f = fixture("stderr-success"),
        write = fs.writeSync;
      let injected = false;
      fs.writeSync = function (fd, chunk, ...args) {
        const text = String(chunk);
        if (
          !injected &&
          text.includes(
            stream === "jsonl" ? "turn.completed" : "controlled UTF-8 stderr",
          )
        ) {
          injected = true;
          const bytes = Buffer.from(chunk);
          const count = bytes.length - 1;
          return write.call(this, fd, bytes, 0, count);
        }
        return write.call(this, fd, chunk, ...args);
      };
      try {
        const { result, receipt } = await controlled(f);
        assert.equal(injected, true);
        assert.match(
          result.error || "",
          new RegExp(`${stream}_write_error: SHORT_WRITE`),
        );
        assert.equal(receipt.trace_complete, false);
        assert.equal(receipt.original_usage, null);
        assert.deepEqual(
          [
            receipt.usage.prompt,
            receipt.usage.cached,
            receipt.usage.completion,
          ],
          [null, null, null],
        );
        if (stream === "jsonl") assert.equal(receipt.completed_turns, 0);
        assert.ok(
          fs.statSync(receipt.paths[stream]).size > 0,
          "preserve the written prefix",
        );
        assert.ok(
          fs.existsSync(
            path.join(f.registry, `${receipt.registration_id}.cancel`),
          ),
        );
      } finally {
        fs.writeSync = write;
        await dispose(f);
      }
    });
  await t.test("complete UTF-8 bytes retain a complete trace", async () => {
    const f = fixture("stderr-success");
    try {
      const { result, receipt } = await controlled(f);
      assert.equal(result.error, undefined);
      assert.equal(receipt.trace_complete, true);
      assert.equal(receipt.usage.prompt, 31);
      assert.equal(
        fs.readFileSync(receipt.paths.stderr, "utf8"),
        "controlled UTF-8 stderr: €\n",
      );
    } finally {
      await dispose(f);
    }
  });
});

test("round5: wall-clock changes do not control admission or receipt waiting", async (t) => {
  await t.test("forward adjustment does not reject valid work", async () => {
    const f = fixture();
    Date.now = () => wallNow() + 3600000;
    try {
      const { result, receipt } = await controlled(f);
      assert.equal(result.error, undefined);
      assert.equal(receipt.cleanup.owned_processes_gone, true);
    } finally {
      Date.now = wallNow;
      await dispose(f);
    }
  });
  await t.test(
    "backward adjustment does not extend missing-receipt waiting",
    async () => {
      // The shared deadline also pays for the pre-launch Git snapshot preflight,
      // whose cost is one fake-git process start per check on this host. Measure
      // it so the trial is admitted and the 1000 ms allowance covers only launch
      // and receipt waiting. A wall-clock deadline would add the 1500 ms shift.
      const probe = fixture();
      let preflightMs;
      try {
        const startedAt = performance.now();
        buildInvocation(probe.manifest, probe.manifest.cases[0]);
        preflightMs = Math.ceil(performance.now() - startedAt);
      } finally {
        await dispose(probe);
      }
      const hardMs = preflightMs + 1000;
      const f = fixture("success", { hardMs, trialMaxMs: 500 });
      Date.now = () => wallNow() - 1500;
      const began = performance.now();
      try {
        const { result, receipt } = await controlled(
          f,
          {},
          { omitReceipt: true },
        );
        assert.match(result.error, /cleanup/i);
        assert.equal(receipt.cleanup, null);
        assert.ok(
          performance.now() - began < hardMs + 800,
          "must persist within the original monotonic allowance",
        );
      } finally {
        Date.now = wallNow;
        await dispose(f);
      }
    },
  );
});

test("round6: review range must identify the existing immutable two-commit snapshot", async (t) => {
  for (const kind of [
    "named",
    "missing",
    "wrong-parent",
    "named-ref",
    "remote",
    "extra-object",
    "oversized-head",
  ])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const state = JSON.parse(fs.readFileSync(f.gitState));
        if (kind === "named") f.provider.manifest.cases[0].base = "main";
        if (kind === "missing") state.missing = state.base;
        if (kind === "wrong-parent") state.parent = "d".repeat(40);
        if (kind === "named-ref") state.ref = "refs/heads/subject";
        if (kind === "remote") state.remote = "origin";
        if (kind === "extra-object") state.extra = "d".repeat(40);
        if (kind === "oversized-head")
          fs.writeFileSync(
            path.join(f.manifest.cases[0].repo, ".git/HEAD"),
            "x".repeat(1024),
          );
        fs.writeFileSync(f.gitState, JSON.stringify(state));
        await assert.rejects(
          controlled(f),
          /immutable commit IDs|Git snapshot preflight|direct child head|named refs or remotes|outside the approved|HEAD metadata exceeds/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(
          !fs.existsSync(path.join(f.manifest.cases[0].repo, ".eval-tmp")),
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
  for (const size of [40, 64])
    await t.test(
      `records verified ${size}-digit IDs and transport denial`,
      async () => {
        const f = fixture();
        try {
          const state = {
            base: "a".repeat(size),
            head: "b".repeat(size),
            tree: "c".repeat(size),
          };
          Object.assign(f.provider.manifest.cases[0], {
            base: state.base,
            head: state.head,
          });
          fs.writeFileSync(f.gitState, JSON.stringify(state));
          fs.writeFileSync(
            path.join(f.manifest.cases[0].repo, ".git/HEAD"),
            state.head + "\n",
          );
          const { result, receipt } = await controlled(f);
          assert.equal(result.error, undefined);
          assert.deepEqual(receipt.review_commits, {
            base: state.base,
            head: state.head,
          });
          assert.deepEqual(
            result.metadata.review_commits,
            receipt.review_commits,
          );
          assert.match(
            receipt.prompt,
            new RegExp(`Review range: ${state.base} to ${state.head}`),
          );
          const calls = fs
            .readFileSync(f.gitRequests, "utf8")
            .trim()
            .split("\n")
            .map(JSON.parse);
          assert.ok(calls.length > 0);
          for (const call of calls) {
            assert.ok(call.args.includes("core.hooksPath=/dev/null"));
            assert.ok(call.args.includes("core.fsmonitor=false"));
            assert.ok(call.args.includes("protocol.allow=never"));
            assert.equal(call.env.GIT_ALLOW_PROTOCOL, "");
            assert.equal(call.env.GIT_CONFIG_GLOBAL, "/dev/null");
            assert.equal(call.env.GIT_NO_LAZY_FETCH, "1");
          }
        } finally {
          await dispose(f);
        }
      },
    );
});

test("round6: generated scratch links do not block current or sibling repeats", async (t) => {
  for (const kind of ["same-case", "sibling-case"])
    await t.test(kind, async () => {
      const f = fixture();
      try {
        const previous = path.join(
          f.manifest.cases[0].repo,
          ".eval-tmp/repeat-0",
        );
        fs.mkdirSync(previous, { recursive: true });
        const empty = path.join(previous, "empty");
        fs.writeFileSync(empty, "");
        fs.linkSync(empty, path.join(previous, "same-empty-file"));
        fs.symlinkSync("empty", path.join(previous, "tool-link"));
        let trial = f.manifest.cases[0];
        if (kind === "sibling-case") {
          const sibling = path.join(f.root, "repo-b");
          createFixtureRepo(sibling);
          trial = {
            ...trial,
            id: "second-pr",
            artifactStem: "case-b",
            repo: sibling,
          };
          f.manifest.cases.push(trial);
        }
        f.provider.manifest = f.manifest;
        const { result, receipt } = await controlled(
          f,
          {},
          {},
          { vars: { case_id: trial.id }, repeatIndex: 1 },
        );
        assert.equal(result.error, undefined);
        assert.equal(
          receipt.permission_profile.filesystem[
            path.join(trial.repo, ".eval-tmp")
          ],
          "deny",
        );
        assert.equal(
          receipt.permission_profile.filesystem[
            path.join(trial.repo, ".eval-tmp/repeat-1")
          ],
          "write",
        );
        assert.equal(
          fs.readlinkSync(path.join(previous, "tool-link")),
          "empty",
        );
        assert.equal(fs.statSync(empty).nlink, 2);
        // Explicit operator evidence still receives the strict link check.
        f.manifest.denyPaths.push(previous);
        assert.throws(
          () => buildInvocation(f.manifest, trial, 2),
          /Hidden evidence must/,
        );
      } finally {
        await dispose(f);
      }
    });
});

test("round7: checkout drift is refused before reserving artifacts or starting a trial", async (t) => {
  const changes = {
    "staged change": { indexChange: "tracked.txt" },
    "unstaged change": { worktreeChange: "tracked.txt" },
    "tracked deletion": { worktreeChange: "removed.txt" },
    "untracked file": { others: ["notes.txt"] },
    "ignored file": { others: ["ignored/generated.txt"] },
    "scratch prefix sibling": { others: [".eval-tmp-extra/notes.txt"] },
    "whitespace-prefixed scratch name": { others: [" .eval-tmp/notes.txt"] },
    "assume unchanged index": { indexEntries: ["h tracked.txt"] },
    "skip worktree index": { indexEntries: ["S tracked.txt"] },
    "configured clean filter": { filter: "filter.example.clean" },
    "configured process filter": { filter: "filter.example.process" },
  };
  for (const [name, change] of Object.entries(changes))
    await t.test(name, async () => {
      const f = fixture();
      try {
        const state = { ...JSON.parse(fs.readFileSync(f.gitState)), ...change };
        fs.writeFileSync(f.gitState, JSON.stringify(state));
        await assert.rejects(
          controlled(f),
          /tracked worktree must match|extra files outside|index must not suppress|unsupported checkout configuration/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(
          !fs.existsSync(path.join(f.manifest.cases[0].repo, ".eval-tmp")),
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
        if (change.filter) {
          const requests = fs
            .readFileSync(f.gitRequests, "utf8")
            .trim()
            .split("\n")
            .map(JSON.parse);
          assert.ok(
            !requests.some(
              ({ args }) =>
                args.includes("diff-index") || args.includes("diff-files"),
            ),
          );
        }
      } finally {
        await dispose(f);
      }
    });
});

test("round7: a Git-clean checkout permits prior scratch and disables external comparisons", async () => {
  const f = fixture();
  try {
    const state = {
      ...JSON.parse(fs.readFileSync(f.gitState)),
      indexEntries: ["H tracked.txt"],
      others: [
        ".eval-tmp/repeat-0/output.txt",
        ".eval-tmp/repeat-0/ignored.txt",
      ],
    };
    fs.writeFileSync(f.gitState, JSON.stringify(state));
    const previous = path.join(f.manifest.cases[0].repo, state.others[0]);
    fs.mkdirSync(path.dirname(previous), { recursive: true });
    fs.writeFileSync(previous, "prior disposable output");
    const { result } = await controlled(
      f,
      {},
      {},
      { vars: { case_id: "original-pr" }, repeatIndex: 1 },
    );
    assert.equal(result.error, undefined);
    assert.equal(fs.readFileSync(previous, "utf8"), "prior disposable output");
    const requests = fs
      .readFileSync(f.gitRequests, "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    const comparisons = requests.filter(
      ({ args }) => args.includes("diff-index") || args.includes("diff-files"),
    );
    assert.equal(comparisons.length, 2);
    for (const { args, env } of comparisons) {
      assert.ok(args.includes("--no-ext-diff"));
      assert.ok(args.includes("--no-textconv"));
      assert.ok(args.includes("core.fsmonitor=false"));
      assert.equal(env.GIT_OPTIONAL_LOCKS, "0");
      if (args.includes("diff-files")) assert.ok(args.includes("--numstat"));
    }
    const inventory = requests.find(({ args }) => args.includes("--others"));
    assert.ok(inventory);
    assert.ok(inventory.args.includes("-z"));
    assert.ok(!inventory.args.some((arg) => arg.startsWith("--exclude")));
  } finally {
    await dispose(f);
  }
});

test("round7: clean copied checkout uses content comparison without writing the index", async () => {
  const f = fixture();
  try {
    const source = f.manifest.cases[0].repo;
    fs.rmSync(path.join(source, ".git"), { recursive: true });
    const gitPath = "/usr/bin/git";
    // Host templates can add metadata outside the review snapshot contract.
    const template = path.join(f.root, "git-template");
    fs.mkdirSync(path.join(template, "branches"), { recursive: true });
    const git = (repo, args) => {
      const result = spawnSync(
        gitPath,
        [
          "-C",
          repo,
          "-c",
          "core.hooksPath=/dev/null",
          "-c",
          "core.fsmonitor=false",
          "-c",
          "commit.gpgsign=false",
          "-c",
          "user.name=Offline fixture",
          "-c",
          "user.email=fixture@example.invalid",
          ...args,
        ],
        {
          encoding: "utf8",
          timeout: 3000,
          maxBuffer: 1024 * 1024,
          env: {
            PATH: "/usr/bin:/bin",
            GIT_CONFIG_NOSYSTEM: "1",
            GIT_CONFIG_GLOBAL: "/dev/null",
            GIT_OPTIONAL_LOCKS: "0",
            GIT_TEMPLATE_DIR: template,
          },
        },
      );
      assert.equal(result.status, 0, result.stderr);
      return result.stdout.trim();
    };
    git(source, ["init", "--template=", "-q", "-b", "subject"]);
    git(source, ["config", "core.logAllRefUpdates", "false"]);
    fs.writeFileSync(path.join(source, "fixture.txt"), "base fixture\n");
    git(source, ["add", "fixture.txt"]);
    git(source, ["commit", "-qm", "base"]);
    const base = git(source, ["rev-parse", "HEAD"]);
    fs.writeFileSync(path.join(source, "fixture.txt"), "subject fixture\n");
    git(source, ["add", "fixture.txt"]);
    git(source, ["commit", "-qm", "subject"]);
    const head = git(source, ["rev-parse", "HEAD"]);
    git(source, ["checkout", "--detach", "-q"]);
    git(source, ["update-ref", "-d", "refs/heads/subject"]);
    for (const entry of ["hooks", "description", "info", "COMMIT_EDITMSG"])
      fs.rmSync(path.join(source, ".git", entry), {
        recursive: true,
        force: true,
      });
    const copied = path.join(f.root, "copied-repo");
    fs.cpSync(source, copied, { recursive: true });
    const tracked = path.join(copied, "fixture.txt"),
      later = new Date(Date.now() + 5000);
    fs.utimesSync(tracked, later, later);
    const index = path.join(copied, ".git/index"),
      before = fs.readFileSync(index);
    assert.equal(
      git(copied, [
        "diff-files",
        "--name-only",
        "--no-ext-diff",
        "--no-textconv",
        "--",
      ]),
      "fixture.txt",
    );
    Object.assign(f.manifest.cases[0], { repo: copied, base, head });
    f.manifest.gitPath = gitPath;
    assert.doesNotThrow(() => buildInvocation(f.manifest, f.manifest.cases[0]));
    assert.deepEqual(
      fs.readFileSync(index),
      before,
      "validation must not refresh the copied index on disk",
    );
    fs.writeFileSync(tracked, "changed subject fixture\n");
    assert.throws(
      () => buildInvocation(f.manifest, f.manifest.cases[0]),
      /tracked worktree must match/,
    );
    assert.deepEqual(fs.readFileSync(index), before);
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    await dispose(f);
  }
});

test("round8: unapproved Git metadata is refused before artifacts or launch", async (t) => {
  for (const name of [
    "notes.txt",
    "MERGE_MSG",
    "hooks/note",
    "info/attributes",
    `objects/pack/pack-${"d".repeat(40)}.tmp`,
    `objects/ab/${"c".repeat(38)}.extra`,
    "index/child",
  ])
    await t.test(name, async () => {
      const f = fixture();
      try {
        const entry = path.join(f.manifest.cases[0].repo, ".git", name);
        fs.mkdirSync(path.dirname(entry), { recursive: true });
        fs.writeFileSync(entry, "inert fixture metadata");
        await assert.rejects(controlled(f), /unapproved Git metadata/);
        assert.equal(fs.readFileSync(entry, "utf8"), "inert fixture metadata");
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
});

test("round8: case configuration and tracked scratch cannot change review visibility", async (t) => {
  const cases = {
    "worktree setting": { worktree: true },
    "bare setting": { config: { "core.bare": "true" } },
    "mode masking": { config: { "core.filemode": "false" } },
    "symlink masking": { config: { "core.symlinks": "false" } },
    "tracked scratch root": { indexEntries: ["H .eval-tmp"] },
    "tracked scratch child": { indexEntries: ["H .eval-tmp/fixture.txt"] },
  };
  for (const [name, change] of Object.entries(cases))
    await t.test(name, async () => {
      const f = fixture();
      try {
        fs.writeFileSync(
          f.gitState,
          JSON.stringify({
            ...JSON.parse(fs.readFileSync(f.gitState)),
            ...change,
          }),
        );
        await assert.rejects(
          controlled(f),
          /redirect its worktree|unsupported checkout configuration|track reserved scratch/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.ok(
          !fs.existsSync(path.join(f.manifest.cases[0].repo, ".eval-tmp")),
        );
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
});

test("round8: approved metadata types preserve packed snapshots and canonical Git binding", async () => {
  const f = fixture();
  try {
    const repo = f.manifest.cases[0].repo,
      gitDir = path.join(repo, ".git");
    for (const name of [
      "config",
      "index",
      "packed-refs",
      `objects/ab/${"c".repeat(38)}`,
      ...["pack", "idx", "rev", "bitmap"].map(
        (ext) => `objects/pack/pack-${"d".repeat(40)}.${ext}`,
      ),
    ]) {
      const entry = path.join(gitDir, name);
      fs.mkdirSync(path.dirname(entry), { recursive: true });
      fs.writeFileSync(entry, "inert metadata placeholder");
    }
    for (const name of ["objects/info", "refs/heads", "refs/tags"])
      fs.mkdirSync(path.join(gitDir, name), { recursive: true });
    fs.writeFileSync(
      f.gitState,
      JSON.stringify({
        ...JSON.parse(fs.readFileSync(f.gitState)),
        config: {
          "core.bare": "false",
          "core.filemode": "true",
          "core.symlinks": "true",
        },
        indexEntries: ["H .eval-tmp-other/fixture.txt"],
      }),
    );
    const alias = path.join(f.root, "repo-alias");
    fs.symlinkSync(repo, alias);
    f.manifest.cases[0].repo = alias;
    assert.doesNotThrow(() => buildInvocation(f.manifest, f.manifest.cases[0]));
    const requests = fs
      .readFileSync(f.gitRequests, "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    assert.ok(requests.length > 0);
    for (const { args } of requests) {
      assert.equal(args[args.indexOf("--git-dir") + 1], gitDir);
      assert.equal(args[args.indexOf("--work-tree") + 1], repo);
    }
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    await dispose(f);
  }
});

test("round9: unsupported Git configuration and index modes are refused before launch", async (t) => {
  const changes = {
    "disabled ctime checks": { config: { "core.trustctime": "false" } },
    "minimal stat checks": { config: { "core.checkstat": "minimal" } },
    "ignored stat checks": { config: { "core.ignorestat": "true" } },
    "config include": { config: { "include.path": "inert-config-path" } },
    "unapproved cache setting": { config: { "core.untrackedcache": "true" } },
    "unapproved setting": { config: { "user.note": "inert value" } },
    "gitlink entry": {
      indexEntries: ["H sub"],
      indexStages: [`H 160000 ${"c".repeat(40)} 0\tsub`],
    },
  };
  for (const [name, change] of Object.entries(changes))
    await t.test(name, async () => {
      const f = fixture();
      try {
        fs.writeFileSync(
          f.gitState,
          JSON.stringify({
            ...JSON.parse(fs.readFileSync(f.gitState)),
            ...change,
          }),
        );
        await assert.rejects(
          controlled(f),
          /unsupported checkout configuration|unsupported modes/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
});

test("unchanged gitlinks require explicit opt-in and empty contents", async (t) => {
  for (const state of ["unchanged", "changed", "deleted", "populated"])
    await t.test(state, async () => {
      const f = fixture();
      try {
        const repo = f.manifest.cases[0].repo,
          gitPath = "/usr/bin/git";
        fs.rmSync(path.join(repo, ".git"), { recursive: true });
        const git = (args) => {
          const result = spawnSync(
            gitPath,
            [
              "-C",
              repo,
              "-c",
              "core.hooksPath=/dev/null",
              "-c",
              "core.fsmonitor=false",
              "-c",
              "commit.gpgsign=false",
              ...args,
            ],
            {
              encoding: "utf8",
              timeout: 3000,
              env: {
                PATH: "/usr/bin:/bin",
                GIT_CONFIG_NOSYSTEM: "1",
                GIT_CONFIG_GLOBAL: "/dev/null",
                GIT_AUTHOR_NAME: "Fixture",
                GIT_AUTHOR_EMAIL: "fixture@example.invalid",
                GIT_COMMITTER_NAME: "Fixture",
                GIT_COMMITTER_EMAIL: "fixture@example.invalid",
              },
            },
          );
          assert.equal(result.status, 0, result.stderr);
          return result.stdout.trim();
        };
        git(["init", "--template=", "-q"]);
        git(["config", "core.logAllRefUpdates", "false"]);
        fs.writeFileSync(path.join(repo, "file.txt"), "base\n");
        git(["add", "file.txt"]);
        git([
          "update-index",
          "--add",
          "--cacheinfo",
          `160000,${"1".repeat(40)},dependency`,
        ]);
        const baseTree = git(["write-tree"]),
          base = git(["commit-tree", baseTree, "-m", "Base"]);
        fs.writeFileSync(path.join(repo, "file.txt"), "head\n");
        git(["add", "file.txt"]);
        if (state === "changed")
          git([
            "update-index",
            "--cacheinfo",
            `160000,${"2".repeat(40)},dependency`,
          ]);
        if (state === "deleted")
          git(["update-index", "--force-remove", "dependency"]);
        const head = git([
          "commit-tree",
          git(["write-tree"]),
          "-p",
          base,
          "-m",
          "Change",
        ]);
        fs.writeFileSync(path.join(repo, ".git/HEAD"), head + "\n");
        for (const entry of ["hooks", "description", "info"])
          fs.rmSync(path.join(repo, ".git", entry), {
            recursive: true,
            force: true,
          });
        if (state !== "deleted") fs.mkdirSync(path.join(repo, "dependency"));
        if (state === "populated")
          fs.writeFileSync(
            path.join(repo, "dependency/source.txt"),
            "unapproved",
          );
        Object.assign(f.manifest.cases[0], { base, head });
        f.manifest.gitPath = gitPath;
        if (state !== "deleted")
          assert.throws(
            () => buildInvocation(f.manifest, f.manifest.cases[0]),
            /unsupported modes/,
          );
        f.manifest.allowUnchangedGitlinks = true;
        if (state === "unchanged") {
          const invocation = buildInvocation(f.manifest, f.manifest.cases[0]);
          assert.deepEqual(invocation.reviewCommits.unchangedGitlinks, [
            "dependency",
          ]);
          assert.match(invocation.prompt, /Their contents are absent/);
        } else
          assert.throws(
            () => buildInvocation(f.manifest, f.manifest.cases[0]),
            /Only unchanged gitlinks|Gitlink contents must be absent/,
          );
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        await dispose(f);
      }
    });
});

test("round9: case files, metadata and roots require trusted ownership and permissions", async (t) => {
  for (const kind of [
    "case root",
    "case file",
    "Git metadata",
    "scratch root",
    "sibling case",
    "foreign owner",
    "replaceable parent",
  ])
    await t.test(kind, async () => {
      const f = fixture(),
        lstat = fs.lstatSync;
      try {
        let target = f.manifest.cases[0].repo;
        if (kind === "case file" || kind === "foreign owner") {
          target = path.join(target, "fixture.txt");
          fs.writeFileSync(target, "ordinary fixture");
        } else if (kind === "Git metadata")
          target = path.join(target, ".git/HEAD");
        else if (kind === "scratch root") {
          target = path.join(target, ".eval-tmp");
          fs.mkdirSync(target, { mode: 0o700 });
        } else if (kind === "sibling case") {
          target = path.join(f.root, "sibling");
          createFixtureRepo(target);
          f.provider.manifest.cases.push({
            ...f.manifest.cases[0],
            id: "second",
            artifactStem: "case-b",
            repo: target,
          });
        } else if (kind === "replaceable parent") {
          const parent = path.join(f.root, "case-parent");
          fs.mkdirSync(parent);
          const moved = path.join(parent, "repo");
          fs.renameSync(target, moved);
          f.provider.manifest.cases[0].repo = moved;
          target = parent;
        }
        if (kind === "foreign owner") {
          fs.lstatSync = function (value, ...args) {
            const info = lstat.call(this, value, ...args);
            if (value === target) info.uid = process.geteuid() + 1;
            return info;
          };
        } else
          fs.chmodSync(target, lstat(target).isDirectory() ? 0o777 : 0o666);
        await assert.rejects(
          controlled(f),
          /Case snapshot must be user-owned|Untrusted case ancestor/,
        );
        assert.ok(!fs.existsSync(f.manifest.resultsDir));
        assert.ok(!fs.existsSync(f.ready));
        assert.deepEqual(fs.readdirSync(f.registry), []);
      } finally {
        fs.lstatSync = lstat;
        await dispose(f);
      }
    });
});

test("round9: supported config, tracked symlinks and isolated prior scratch remain usable", async () => {
  const f = fixture();
  try {
    const repo = f.manifest.cases[0].repo,
      target = path.join(repo, "fixture.txt");
    fs.writeFileSync(target, "ordinary fixture");
    fs.symlinkSync("fixture.txt", path.join(repo, "fixture-link"));
    const previous = path.join(repo, ".eval-tmp/repeat-0");
    fs.mkdirSync(previous, { recursive: true, mode: 0o700 });
    fs.writeFileSync(
      path.join(previous, "old-output"),
      "prior disposable output",
    );
    fs.chmodSync(path.join(previous, "old-output"), 0o666);
    fs.symlinkSync("old-output", path.join(previous, "tool-link"));
    const alias = path.join(f.root, "case-alias");
    fs.symlinkSync(repo, alias);
    f.manifest.cases[0].repo = alias;
    fs.writeFileSync(
      f.gitState,
      JSON.stringify({
        ...JSON.parse(fs.readFileSync(f.gitState)),
        config: {
          "core.repositoryformatversion": "0",
          "core.filemode": "true",
          "core.symlinks": "true",
          "core.bare": "false",
          "core.logallrefupdates": "false",
          "core.ignorecase": "true",
          "core.precomposeunicode": "true",
          "core.trustctime": "true",
          "core.checkstat": "default",
          "core.ignorestat": "false",
          "core.fsmonitor": "false",
        },
        indexStages: [
          `H 100644 ${"c".repeat(40)} 0\tfixture.txt`,
          `H 120000 ${"d".repeat(40)} 0\tfixture-link`,
        ],
      }),
    );
    const invocation = buildInvocation(f.manifest, f.manifest.cases[0], 1);
    assert.equal(invocation.args[invocation.args.indexOf("--cd") + 1], repo);
    assert.equal(invocation.repo, repo);
    assert.equal(invocation.scratch, path.join(repo, ".eval-tmp/repeat-1"));
    assert.equal(
      fs.readlinkSync(path.join(repo, "fixture-link")),
      "fixture.txt",
    );
    assert.equal(
      fs.readFileSync(path.join(previous, "old-output"), "utf8"),
      "prior disposable output",
    );
    const requests = fs
      .readFileSync(f.gitRequests, "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    const config = requests.find(({ args }) => args.includes("config"));
    assert.ok(config.args.includes("--no-includes"));
    assert.equal(
      config.args[config.args.indexOf("--file") + 1],
      path.join(repo, ".git/config"),
    );
    assert.ok(!fs.existsSync(f.manifest.resultsDir));
    assert.ok(!fs.existsSync(f.ready));
  } finally {
    await dispose(f);
  }
});

test("round9: untracked inventory uses case-sensitive path comparison", async () => {
  const f = fixture();
  try {
    fs.writeFileSync(
      f.gitState,
      JSON.stringify({
        ...JSON.parse(fs.readFileSync(f.gitState)),
        config: { "core.ignorecase": "true" },
      }),
    );
    assert.doesNotThrow(() => buildInvocation(f.manifest, f.manifest.cases[0]));
    const requests = fs
      .readFileSync(f.gitRequests, "utf8")
      .trim()
      .split("\n")
      .map(JSON.parse);
    const inventory = requests.find(({ args }) => args.includes("--others"));
    assert.ok(inventory.args.includes("core.ignorecase=false"));
    assert.ok(inventory.args.includes("-z"));
    assert.ok(!inventory.args.some((arg) => arg.startsWith("--exclude")));
  } finally {
    await dispose(f);
  }
});

test("uncapped execution preserves final output, null limit and no cutoff instruction", async () => {
  const f = fixture("success", { trialMaxMs: null });
  try {
    const { result, receipt } = await controlled(f);
    assert.equal(result.error, undefined);
    assert.equal(receipt.trial_max_ms, null);
    assert.equal(receipt.execution_mode, "uncapped");
    assert.match(receipt.prompt, /no work time limit/);
    assert.doesNotMatch(receipt.prompt, /hard cutoff|before the cutoff/);
    assert.equal(JSON.parse(result.output).supervisorEnvAbsent, true);
  } finally {
    await dispose(f);
  }
});

test("uncapped abort still requests owner cleanup and retains partial output", async () => {
  const f = fixture("hang", { trialMaxMs: null }),
    abort = new AbortController();
  const trigger = setInterval(() => {
    if (fs.existsSync(f.ready)) abort.abort();
  }, 5);
  try {
    const { result, receipt, requested } = await controlled(f, {
      abortSignal: abort.signal,
    });
    assert.equal(result.error, "aborted");
    assert.equal(requested, true);
    assert.equal(receipt.cleanup.owned_processes_gone, true);
    assert.match(
      fs.readFileSync(receipt.paths.jsonl, "utf8"),
      /preserve this prefix/,
    );
  } finally {
    clearInterval(trigger);
    await dispose(f);
  }
});

test("uncapped missing cleanup receipt stops observation after actual exit", async () => {
  const f = fixture("success", { trialMaxMs: null }),
    began = performance.now();
  try {
    const { result, receipt } = await controlled(f, {}, { omitReceipt: true });
    assert.match(result.error, /cleanup unverified/i);
    assert.equal(receipt.trace_complete, true);
    assert.equal(receipt.cleanup, null);
    assert.ok(performance.now() - began < 5000);
  } finally {
    await dispose(f);
  }
});

test("uncapped execution refuses mixed deadline contracts before launch", async () => {
  for (const override of [
    { EVAL_CAMPAIGN_EXECUTION_MODE: "bounded" },
    { EVAL_CAMPAIGN_TRIAL_MAX_MS: "3000" },
    { EVAL_CAMPAIGN_WORK_DEADLINE_MONOTONIC: "Infinity" },
    { EVAL_CAMPAIGN_CLEANUP_SECONDS: "Infinity" },
    { EVAL_CAMPAIGN_CLEANUP_SECONDS: "0" },
  ]) {
    const f = fixture("success", { trialMaxMs: null });
    try {
      Object.assign(process.env, override);
      const { result } = await controlled(f);
      assert.match(result.error, /execution mode mismatch/);
      assert.equal(fs.existsSync(f.ready), false);
    } finally {
      await dispose(f);
    }
  }
});

test("uncapped terminal events and malformed traces cancel a subject that remains alive", async () => {
  for (const mode of ["error-hang", "invalid-hang"]) {
    const f = fixture(mode, { trialMaxMs: null });
    try {
      const { result, receipt, requested } = await controlled(f);
      assert.match(result.error, /terminal fixture failure|Invalid JSONL/);
      assert.equal(requested, true);
      assert.equal(receipt.cleanup.reason, "provider_abort");
      assert.equal(receipt.cleanup.owned_processes_gone, true);
      assert.equal(receipt.completed_turns, 0);
    } finally {
      await dispose(f);
    }
  }
});
