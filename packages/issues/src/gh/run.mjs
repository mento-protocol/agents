/**
 * The bounded `gh` runner.
 *
 * Ported from monitoring-monorepo `scripts/pr/issue-board-transport.mjs`
 * (`quoteArg`, `formatGh`, `runGh`, `sleep`, lines 24-31 and 61-125 and
 * 258-262). Kept byte-for-byte in behaviour:
 *
 *   - `spawn("gh", args, { env, stdio })` with the raw argv array. No shell,
 *     anywhere, ever.
 *   - per-chunk `Buffer.byteLength` accounting against a 20 MiB cap, with the
 *     child killed and a single rejection.
 *   - `dryRun && mutates` skips the subprocess and resolves `""`. NOTE THE
 *     TRAP: `dryRun` alone does NOT suppress reads. A read under `--dry-run`
 *     still spawns `gh` and still reaches GitHub.
 *
 * Added here:
 *
 *   - a wall-clock timeout: `SIGTERM` at `timeoutMs`, `SIGKILL` at
 *     `+killGraceMs`, both timers `unref()`'d so they never hold the process
 *     open. A timeout on a `mutates: true` call is an UNKNOWN outcome that must
 *     feed the reconcile path, never a definitive failure.
 *   - an `AbortSignal`.
 *   - typed errors (see `./errors.mjs`).
 *   - `redactSecrets` plus 4 KiB truncation before any stderr reaches a
 *     message, a hint or a JSON result.
 *
 * Cut: monitoring's stdin `input` path. This package never posts a body.
 */

import { spawn as spawnChildProcess } from "node:child_process";

import {
  GhAbortError,
  GhCommandError,
  GhEnvError,
  GhOutputLimitError,
  GhPermissionError,
  GhTimeoutError,
} from "./errors.mjs";
import { pinnedGithubCliEnvironment } from "./env.mjs";
import {
  CLOUD_SESSION_GATEWAY_BODY,
  githubContentsScopeHint,
} from "./hints.mjs";
import { safeStderr } from "./redact.mjs";

export const GH_OUTPUT_MAX_BYTES = 20 * 1024 * 1024;
export const GH_DEFAULT_TIMEOUT_MS = 60_000;
export const GH_KILL_GRACE_MS = 5_000;

const HTTP_STATUS_PATTERN = /\bHTTP\s+(\d{3})\b/;
const MISSING_SCOPE_PATTERN = /requires one of the following scopes/i;

/**
 * Shell-safe rendering of one argv entry, for messages and logs only. Nothing
 * this produces is ever executed.
 *
 * @param {string} value
 * @returns {string}
 */
export function quoteArg(value) {
  if (/^[A-Za-z0-9_./:=@#-]+$/.test(value)) return value;
  return JSON.stringify(value);
}

/**
 * Render a `gh` argv for a message or a log line.
 *
 * @param {Array<string|number>} args
 * @returns {string}
 */
export function formatGh(args) {
  return `gh ${args.map((arg) => quoteArg(String(arg))).join(" ")}`;
}

/**
 * Plain promise delay. Injected into the reconcile loop so tests run instantly.
 *
 * @param {number} ms
 * @returns {Promise<void>}
 */
export function sleep(ms) {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

/**
 * The HTTP status `gh` reported, or `null`.
 *
 * Covers both shapes `gh` prints: `gh: Not Found (HTTP 404)` and
 * `HTTP 403: Resource not accessible`.
 *
 * @param {string} stderr
 * @returns {number|null}
 */
export function parseHttpStatus(stderr) {
  const match = String(stderr ?? "").match(HTTP_STATUS_PATTERN);
  if (!match) return null;
  const status = Number.parseInt(match[1], 10);
  return Number.isSafeInteger(status) ? status : null;
}

function isPermissionFailure(stderr, httpStatus) {
  if (httpStatus === 401 || httpStatus === 403) return true;
  if (stderr.includes(CLOUD_SESSION_GATEWAY_BODY)) return true;
  return MISSING_SCOPE_PATTERN.test(stderr);
}

function normalizeArgs(args) {
  if (!Array.isArray(args) || args.length === 0) {
    throw new GhEnvError("gh requires a non-empty argv array");
  }
  return args.map((arg) => {
    if (typeof arg === "string") return arg;
    if (typeof arg === "number" && Number.isFinite(arg)) return String(arg);
    throw new GhEnvError(
      `gh argv entries must be strings or finite numbers, got: ${typeof arg}`,
    );
  });
}

function writeToStderr(text) {
  process.stderr.write(text);
}

/**
 * Run `gh` with bounded output, a wall-clock timeout and typed failures.
 *
 * @param {Array<string|number>} args argv passed to `gh` verbatim, no shell.
 * @param {object} [options]
 * @param {boolean} [options.dryRun] with `mutates`, skip the subprocess.
 * @param {boolean} [options.mutates] does this call change server state?
 * @param {number} [options.timeoutMs] wall clock budget; `0` disables it.
 * @param {number} [options.killGraceMs] `SIGTERM` to `SIGKILL` delay.
 * @param {number} [options.maxBytes] per-stream output cap.
 * @param {NodeJS.ProcessEnv} [options.env] environment to pin and pass on.
 * @param {AbortSignal|null} [options.signal]
 * @param {((chunk: string) => void)|null} [options.stderrSink] live stderr tap.
 * @param {Function} [options.spawn] injected `child_process.spawn`, for tests.
 * @param {(text: string) => void} [options.writeNotice] dry-run notice sink.
 * @returns {Promise<string>} stdout on success.
 */
export function runGh(
  args,
  {
    dryRun = false,
    mutates = false,
    timeoutMs = GH_DEFAULT_TIMEOUT_MS,
    killGraceMs = GH_KILL_GRACE_MS,
    maxBytes = GH_OUTPUT_MAX_BYTES,
    env = process.env,
    signal = null,
    stderrSink = null,
    spawn = spawnChildProcess,
    writeNotice = writeToStderr,
  } = {},
) {
  const argv = normalizeArgs(args);
  const pinnedEnvironment = pinnedGithubCliEnvironment(env);

  if (dryRun && mutates) {
    writeNotice(`[dry-run] ${formatGh(argv)}\n`);
    return Promise.resolve("");
  }

  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(
        new GhAbortError(`${formatGh(argv)} was aborted before it started`, {
          args: argv,
          mutates,
        }),
      );
      return;
    }

    const child = spawn("gh", argv, {
      env: pinnedEnvironment,
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    let stdoutBytes = 0;
    let stderrBytes = 0;
    let settled = false;
    let timeoutTimer = null;
    let killTimer = null;
    let abortListener = null;

    function clearAbortListener() {
      if (abortListener && signal) {
        signal.removeEventListener("abort", abortListener);
        abortListener = null;
      }
    }

    function clearTimeoutTimer() {
      if (timeoutTimer) {
        clearTimeout(timeoutTimer);
        timeoutTimer = null;
      }
    }

    function settleResolve(value) {
      if (settled) return;
      settled = true;
      clearTimeoutTimer();
      clearAbortListener();
      resolve(value);
    }

    function settleReject(error) {
      if (settled) return;
      settled = true;
      clearTimeoutTimer();
      clearAbortListener();
      reject(error);
    }

    /** Kill the child, escalating to `SIGKILL`, then reject. */
    function terminate(error) {
      if (settled) return;
      try {
        child.kill("SIGTERM");
      } catch {
        // The child is already gone; the rejection below still stands.
      }
      killTimer = setTimeout(() => {
        try {
          child.kill("SIGKILL");
        } catch {
          // Already reaped.
        }
      }, killGraceMs);
      killTimer.unref?.();
      settleReject(error);
    }

    if (Number.isFinite(timeoutMs) && timeoutMs > 0) {
      timeoutTimer = setTimeout(() => {
        terminate(
          new GhTimeoutError(
            `${formatGh(argv)} exceeded its ${timeoutMs} ms budget and was terminated; the server-side outcome is unknown`,
            { args: argv, timeoutMs, mutates },
          ),
        );
      }, timeoutMs);
      timeoutTimer.unref?.();
    }

    if (signal) {
      abortListener = () => {
        terminate(
          new GhAbortError(
            `${formatGh(argv)} was aborted and terminated; the server-side outcome is unknown`,
            { args: argv, mutates },
          ),
        );
      };
      signal.addEventListener("abort", abortListener, { once: true });
    }

    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");

    child.stdout.on("data", (chunk) => {
      stdoutBytes += Buffer.byteLength(chunk);
      if (stdoutBytes > maxBytes) {
        terminate(
          new GhOutputLimitError(
            `${formatGh(argv)} stdout exceeded ${maxBytes} bytes`,
            { args: argv, stream: "stdout", limitBytes: maxBytes, mutates },
          ),
        );
        return;
      }
      stdout += chunk;
    });

    child.stderr.on("data", (chunk) => {
      stderrBytes += Buffer.byteLength(chunk);
      if (stderrSink) {
        try {
          stderrSink(chunk);
        } catch {
          // A failing log sink never changes the command's outcome.
        }
      }
      if (stderrBytes > maxBytes) {
        terminate(
          new GhOutputLimitError(
            `${formatGh(argv)} stderr exceeded ${maxBytes} bytes`,
            { args: argv, stream: "stderr", limitBytes: maxBytes, mutates },
          ),
        );
        return;
      }
      stderr += chunk;
    });

    child.on("error", (error) => {
      // A missing or unexecutable `gh` is a local environment fault, not a
      // transport one. Reported as transport it maps to exit 20, whose advice
      // is "retry with backoff", and an agent would spend its whole budget
      // retrying a fault that can never clear.
      const unexecutable = error?.code === "ENOENT" || error?.code === "EACCES";
      settleReject(
        unexecutable
          ? new GhEnvError(
              `${formatGh(argv)} could not be executed (${error.code}): is the gh CLI installed and on PATH?`,
              { args: argv, cause: error },
            )
          : new GhCommandError(
              `${formatGh(argv)} failed: ${safeStderr(error.message)}`,
              { args: argv, cause: error },
            ),
      );
    });

    child.on("close", (status, closeSignal) => {
      if (killTimer) {
        clearTimeout(killTimer);
        killTimer = null;
      }
      if (settled) return;
      if (status !== 0) {
        const safe = safeStderr(stderr);
        const hint = githubContentsScopeHint(safe, env, argv);
        const httpStatus = parseHttpStatus(safe);
        const message = `${formatGh(argv)} failed with exit ${status}:\n${safe}${hint ? `\n${hint}\n` : ""}`;
        const details = {
          args: argv,
          exitCode: status,
          signal: closeSignal ?? null,
          stderr: safe,
          httpStatus,
          hint,
        };
        settleReject(
          isPermissionFailure(safe, httpStatus)
            ? new GhPermissionError(message, details)
            : new GhCommandError(message, details),
        );
        return;
      }
      settleResolve(stdout);
    });
  });
}
