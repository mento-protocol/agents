/**
 * Typed errors for the bounded `gh` runner.
 *
 * Monitoring rejects every transport failure with a plain `Error` carrying a
 * formatted message. The claims layer needs to tell three outcomes apart:
 *
 *   - the command ran and GitHub answered with a failure (`GhCommandError`);
 *   - the command was terminated by us, so the outcome is UNKNOWN
 *     (`GhTimeoutError`, `GhAbortError`, `GhOutputLimitError`);
 *   - the process refused to run at all (`GhEnvError`).
 *
 * A terminated mutating call must feed `advanceRef`'s reconcile path as an
 * unknown outcome, never as a definitive failure, so the terminated classes
 * deliberately do NOT extend `GhCommandError`.
 */

/** Base class for every transport error this package raises. */
export class GhError extends Error {
  /**
   * @param {string} message human-readable, already redacted and truncated.
   * @param {{ args?: string[], code?: string, cause?: unknown }} [details]
   */
  constructor(message, details = {}) {
    super(
      message,
      details.cause === undefined ? undefined : { cause: details.cause },
    );
    this.name = "GhError";
    this.code = details.code ?? "GH_ERROR";
    this.args = Object.freeze([...(details.args ?? [])]);
  }
}

/** The ambient environment is not a canonical `gh` environment. */
export class GhEnvError extends GhError {
  constructor(message, details = {}) {
    super(message, { code: "GH_ENV", ...details });
    this.name = "GhEnvError";
  }
}

/**
 * `gh` ran and exited non-zero. The outcome is definitive: GitHub answered.
 */
export class GhCommandError extends GhError {
  /**
   * @param {string} message
   * @param {{ args?: string[], exitCode?: number|null, signal?: string|null,
   *           stderr?: string, httpStatus?: number|null, hint?: string,
   *           code?: string, cause?: unknown }} [details]
   */
  constructor(message, details = {}) {
    super(message, { code: "GH_COMMAND_FAILED", ...details });
    this.name = "GhCommandError";
    this.exitCode = details.exitCode ?? null;
    this.signal = details.signal ?? null;
    this.stderr = details.stderr ?? "";
    this.httpStatus = details.httpStatus ?? null;
    this.hint = details.hint ?? "";
  }
}

/**
 * We killed `gh` at the wall-clock timeout. The outcome is UNKNOWN: the request
 * may well have been applied server-side.
 */
export class GhTimeoutError extends GhError {
  constructor(message, details = {}) {
    super(message, { code: "GH_TIMEOUT", ...details });
    this.name = "GhTimeoutError";
    this.timeoutMs = details.timeoutMs ?? null;
    this.mutates = details.mutates === true;
    this.outcomeUnknown = true;
  }
}

/**
 * The caller's `AbortSignal` fired. Like a timeout, the outcome is UNKNOWN.
 */
export class GhAbortError extends GhError {
  constructor(message, details = {}) {
    super(message, { code: "GH_ABORTED", ...details });
    this.name = "GhAbortError";
    this.mutates = details.mutates === true;
    this.outcomeUnknown = true;
  }
}

/**
 * A stream ran past the output cap and the child was killed. The outcome is
 * UNKNOWN for the same reason a timeout is.
 */
export class GhOutputLimitError extends GhError {
  constructor(message, details = {}) {
    super(message, { code: "GH_OUTPUT_LIMIT", ...details });
    this.name = "GhOutputLimitError";
    this.stream = details.stream ?? null;
    this.limitBytes = details.limitBytes ?? null;
    this.mutates = details.mutates === true;
    this.outcomeUnknown = true;
  }
}

/**
 * `gh` exited non-zero with a credential or session problem: HTTP 401/403, a
 * missing OAuth scope, or the cloud-session GitHub gateway. Definitive.
 */
export class GhPermissionError extends GhCommandError {
  constructor(message, details = {}) {
    super(message, { code: "GH_PERMISSION", ...details });
    this.name = "GhPermissionError";
  }
}

/**
 * Was this failure produced by terminating the child rather than by GitHub
 * answering? Such a call's server-side effect is unknown.
 *
 * @param {unknown} error
 * @returns {boolean}
 */
export function isUnknownOutcomeError(error) {
  return (
    error instanceof GhTimeoutError ||
    error instanceof GhAbortError ||
    error instanceof GhOutputLimitError
  );
}
