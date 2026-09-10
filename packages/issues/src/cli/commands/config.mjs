/**
 * `config show` and `config validate`.
 *
 * Both do the same work, because loading a config already validates it: every
 * rule in PLAN §2.18 is enforced before the document is normalized, and every
 * failure is exit 3 raised before any network call. `show` prints the
 * normalized document; `validate` prints the same thing plus the checks that
 * passed, so a policy change can be reviewed without running a claim.
 */

import { CONFIG_SCHEMAS, describeConfig } from "../config.mjs";

/**
 * @param {object} runtime the CLI runtime.
 * @returns {Promise<object>} a command result.
 */
export async function runConfig(runtime) {
  const config = runtime.config;
  const body = {
    config: describeConfig(config),
  };
  if (runtime.key === "config validate") {
    body.valid = true;
    body.checks = {
      schema: config.schema,
      retiredSchemaRejected: CONFIG_SCHEMAS.RETIRED_POLICY,
      profile: config.claims.profile,
      namespace: config.claims.namespace,
      scopeTemplate: config.claims.scopeTemplate,
      leaseInvariants: config.profile.leaseCapable
        ? {
            renewTwiceWithinTtl:
              config.claims.renewMinutes * 2 <= config.claims.ttlMinutes,
            minRemainingBelowRenewWindow:
              config.claims.minRemainingSeconds * 1000 <
              config.claims.renewMinutes * 60_000,
            ttlWithinCeiling:
              config.claims.ttlMinutes <= config.claims.maxTtlMinutes,
          }
        : null,
      package: config.claims.package,
    };
  }
  return { status: "ok", body };
}
