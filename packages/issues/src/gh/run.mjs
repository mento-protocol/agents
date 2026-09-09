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
 *   - `redactSecrets` on the ARGV too, on every surface that renders or
 *     carries it: a message, a dry-run notice and the `args` array an error
 *     exposes. Monitoring redacts none of these, so a token passed inside an
 *     argv element — `-H "Authorization: token ghp_…"` — reached all three
 *     verbatim.
 *   - `redactSecrets` on the live `stderrSink`, which received raw chunks
 *     while the error message beside it was redacted.
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
import { REDACTION, redactSecrets, safeStderr } from "./redact.mjs";

export const GH_OUTPUT_MAX_BYTES = 20 * 1024 * 1024;
export const GH_DEFAULT_TIMEOUT_MS = 60_000;
export const GH_KILL_GRACE_MS = 5_000;

const HTTP_STATUS_PATTERN = /\bHTTP\s+(\d{3})\b/;
const MISSING_SCOPE_PATTERN = /requires one of the following scopes/i;

/**
 * Shell-safe rendering of one argv entry, for messages and logs only. Nothing
 * this produces is ever executed.
 *
 * Token shapes are redacted before the entry is quoted, so an argv element
 * carrying a credential cannot reach a message or a log line. Redaction runs
 * first for the same reason it precedes truncation: quoting a token first can
 * split it out of the pattern's reach.
 *
 * @param {string} value
 * @returns {string}
 */
export function quoteArg(value) {
  const safe = redactSecrets(value);
  if (/^[A-Za-z0-9_./:=@#-]+$/.test(safe)) return safe;
  return JSON.stringify(safe);
}

/**
 * Render a `gh` argv for a message or a log line. Redacted, through
 * `quoteArg`.
 *
 * @param {Array<string|number>} args
 * @returns {string}
 */
export function formatGh(args) {
  return `gh ${args.map((arg) => quoteArg(String(arg))).join(" ")}`;
}

/**
 * The argv an error may carry: every entry redacted.
 *
 * `GhError` freezes this array onto `error.args`, where a caller logs it or
 * serializes it into a JSON result, so it is a diagnostic surface exactly like
 * the message. The spawned child still receives the raw argv.
 *
 * @param {string[]} argv
 * @returns {string[]}
 */
function redactArgv(argv) {
  return argv.map((arg) => redactSecrets(arg));
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

/** The characters a GitHub token is made of, so a run of them may still be one. */
const SECRET_TAIL_PATTERN = /[A-Za-z0-9_]*$/u;

/**
 * An `Authorization` header at the very end of the buffer, however incomplete.
 *
 * `redactSecrets` redacts an `Authorization` value by **position**, so it needs
 * the header word and the credential in one string. This is what recognizes a
 * header whose credential has not arrived — or has not ended — yet, so the
 * whole of it is held back rather than forwarded ahead of its own value.
 *
 * Everything after the header word is optional, because a chunk can end
 * anywhere: after `Authorization`, inside the whitespace before its colon,
 * after the colon, after the scheme, or part-way through the value. The
 * whitespace class is `redactSecrets`'s own, so a header split over a line break
 * is held exactly as one is redacted. Group 1 is the part that carries no
 * credential — word, punctuation, scheme — and group 2 is what has arrived of
 * the value.
 */
const PENDING_AUTHORIZATION_PATTERN =
  /(authorization\s*(?::\s*(?:(?:bearer|token|basic)\b\s*)?)?)(\S*)$/iu;

/** Longest tail held back while the rest of a possible token is awaited. */
const STDERR_SINK_HOLD_BACK_MAX_CHARS = 512;

/**
 * Redact a live stderr tap without losing a credential split across chunks.
 *
 * `redactSecrets` matches a whole token, so redacting each chunk on its own
 * would miss one that straddles a chunk boundary. This filter forwards only the
 * redacted text up to the last character that cannot belong to a credential,
 * and holds the rest back until the next chunk or the flush. Two things are
 * held:
 *
 *   - the trailing run of token characters, which is what rejoins a `ghp_…`
 *     split across two chunks;
 *   - an `Authorization` header at the end of the buffer together with as much
 *     of its value as has arrived. Holding only the token run was the leak:
 *     `Authorization: token <40 hex>` in one chunk with no trailing separator
 *     forwarded `Authorization: token ` immediately and flushed the bare
 *     credential afterwards, where positional redaction no longer had a header
 *     to key on and no pattern matches a 40-hex string on purpose. The same
 *     went for `Authorization: Bearer ` and its value in the next chunk, whose
 *     token run is empty, and for a split between the header word and its own
 *     colon.
 *
 * The hold-back is capped at `STDERR_SINK_HOLD_BACK_MAX_CHARS`, and which part
 * of a header outgrew the cap decides what happens:
 *
 *   - the **value**: the header this filter has already parsed is forwarded
 *     verbatim — word, colon and scheme carry no credential — with the
 *     redaction in place of the value, and the rest of that run is dropped.
 *     Forwarding its tail in clear is the one thing this filter exists to
 *     prevent.
 *   - the **whitespace** inside the header, which is a credential nowhere: the
 *     run is squeezed to a single space and the header context is kept, so a
 *     value that arrives afterwards is still redacted. Only that whitespace is
 *     lost.
 *
 * A token run over the cap that is not part of a header is forwarded rather
 * than grown without bound, as before.
 *
 * The filter is flushed when stderr **ends**, never when the promise settles.
 * A rejection can arrive first — an abort or a timeout terminates the child
 * while it is still writing — and flushing there ended the parsing context
 * mid-header, leaving the credential in the next chunk with nothing in front
 * of it.
 *
 * @param {(chunk: string) => void} sink the caller's tap.
 * @returns {{write: (chunk: string) => void, flush: () => void}}
 */
function createStderrSinkFilter(sink) {
  let pending = "";
  // Set once an over-long `Authorization` value has been redacted: the rest of
  // that value is dropped, up to the whitespace that ends it.
  let droppingValue = false;
  const forward = (text) => {
    if (text.length === 0) return;
    try {
      sink(text);
    } catch {
      // A failing log sink never changes the command's outcome.
    }
  };
  const consume = (isFinal) => {
    if (droppingValue) {
      const end = /\s/u.exec(pending);
      if (!end) {
        pending = "";
        return;
      }
      droppingValue = false;
      pending = pending.slice(end.index);
    }
    if (isFinal) {
      forward(redactSecrets(pending));
      pending = "";
      return;
    }
    const header = PENDING_AUTHORIZATION_PATTERN.exec(pending);
    const tail = SECRET_TAIL_PATTERN.exec(pending)[0];
    let holdFrom = pending.length - tail.length;
    if (header && header.index < holdFrom) holdFrom = header.index;
    if (pending.length - holdFrom > STDERR_SINK_HOLD_BACK_MAX_CHARS) {
      if (header && header.index === holdFrom) {
        const [, prefix, value] = header;
        const before = redactSecrets(pending.slice(0, holdFrom));
        if (value.length > STDERR_SINK_HOLD_BACK_MAX_CHARS) {
          forward(`${before}${prefix}${REDACTION}`);
          pending = "";
          droppingValue = true;
          return;
        }
        // Whitespace, not the value, filled the buffer. Squeeze it and keep
        // parsing: the value has not arrived yet and must still be redacted.
        forward(before);
        pending = `${prefix.replaceAll(/\s+/gu, " ")}${value}`;
        return;
      }
      holdFrom = pending.length;
    }
    forward(redactSecrets(pending.slice(0, holdFrom)));
    pending = pending.slice(holdFrom);
  };
  return {
    write(chunk) {
      pending += chunk;
      consume(false);
    },
    flush() {
      consume(true);
    },
  };
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
 * @param {((chunk: string) => void)|null} [options.stderrSink] live stderr tap;
 *   it receives redacted text, one chunk behind a possible token.
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
  // The child is spawned with `argv`; every diagnostic carries `safeArgv`.
  const safeArgv = redactArgv(argv);
  const pinnedEnvironment = pinnedGithubCliEnvironment(env);

  if (dryRun && mutates) {
    writeNotice(`[dry-run] ${formatGh(argv)}\n`);
    return Promise.resolve("");
  }

  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(
        new GhAbortError(`${formatGh(argv)} was aborted before it started`, {
          args: safeArgv,
          mutates,
        }),
      );
      return;
    }

    const child = spawn("gh", argv, {
      env: pinnedEnvironment,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const stderrFilter = stderrSink ? createStderrSinkFilter(stderrSink) : null;
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

    // Neither settler flushes the tap. The promise can settle while the child
    // is still writing — an abort or a timeout terminates it mid-stream — and a
    // flush there ends the filter's parsing context, so an `Authorization`
    // header already forwarded leaves the credential in the next chunk with
    // nothing in front of it to key on. Only the end of the stream flushes.
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
            { args: safeArgv, timeoutMs, mutates },
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
            { args: safeArgv, mutates },
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
            { args: safeArgv, stream: "stdout", limitBytes: maxBytes, mutates },
          ),
        );
        return;
      }
      stdout += chunk;
    });

    child.stderr.on("data", (chunk) => {
      stderrBytes += Buffer.byteLength(chunk);
      stderrFilter?.write(chunk);
      if (stderrBytes > maxBytes) {
        terminate(
          new GhOutputLimitError(
            `${formatGh(argv)} stderr exceeded ${maxBytes} bytes`,
            { args: safeArgv, stream: "stderr", limitBytes: maxBytes, mutates },
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
              { args: safeArgv, cause: error },
            )
          : new GhCommandError(
              `${formatGh(argv)} failed: ${safeStderr(error.message)}`,
              { args: safeArgv, cause: error },
            ),
      );
    });

    child.on("close", (status, closeSignal) => {
      if (killTimer) {
        clearTimeout(killTimer);
        killTimer = null;
      }
      // The one flush. `close` is the end of the child's output, so the tap
      // parses every chunk in one context however early the promise settled,
      // and a chunk that arrived after a timeout still reaches the sink.
      stderrFilter?.flush();
      if (settled) return;
      if (status !== 0) {
        const safe = safeStderr(stderr);
        const hint = githubContentsScopeHint(safe, env, argv);
        const httpStatus = parseHttpStatus(safe);
        const message = `${formatGh(argv)} failed with exit ${status}:\n${safe}${hint ? `\n${hint}\n` : ""}`;
        const details = {
          args: safeArgv,
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
