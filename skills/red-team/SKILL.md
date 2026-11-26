---
name: red-team
description: "Pre-release whole-repo red-team-style security sweep using narrow attack-class hunters. Glasswing-shaped: Static Analysis → Recon → Hunt (parallel narrow hunters) → Validate (Codex disproves) → Dedup → Report. Distinct from /review (per-PR diff scope) and the built-in /security-review (single-pass diff review). Triggers on: 'red team', 'red-team', '/red-team', 'security review', 'security sweep', 'pre-release security', 'scan for vulns'. Its bundled attack classes target Mento's TypeScript services; run it against any repository via --repo PATH with --attack-classes."
---

# Red Team

Pre-release exploratory security sweep. Whole-repo scope (not diff). Adapts Cloudflare Project Glasswing's load-bearing primitives — architecture-grounded recon, narrow attack-class hunters, adversarial validate — to the Claude Code subagent harness.

> **On the name.** "Red Team" here is shorthand for _red-team-style review_ — narrow attack-class hunters paired with an adversarial validator. It is NOT active exploitation, simulated phishing, or social engineering. No code is executed against running systems; no payloads are sent. Findings are produced by reading the code through attacker-shaped prompts and adversarially validated by a different model. Treat the output the same way you'd treat any other code review.

**Research basis:** Cloudflare's published write-up of Project Glasswing, its parallel cyber-frontier security pipeline.

**Why this exists vs `/review`:** `/review` is diff-scoped per-PR and includes
direct security inspection. External Claude Security and Codex Security scans
are opt-in under its shared policy, not automatic consequences of a security
review. This skill is repo-scoped and runs only when explicitly invoked
(pre-release). Its narrow-class hunters found 4× as many findings as the broad
lens in its first validation experiment. That experiment did not compare
against the later Claude Security/Codex Security pairing.

## When to Use

- `security review`, `security sweep`, `run the security review`, `/red-team`
- `pre-release security pass`, `sec sweep before shipping`, `scan for vulns`
- Pointing at a non-monorepo Mento repo: `security review --repo /path/to/bold --attack-classes solidity-mento`

**For per-PR security review, use `/review`** and its direct-review policy;
external scanners run only when explicitly requested or required by repository
policy. Use this skill for whole-repository passes.

## CLI

```text
/red-team                          # sweep cwd, auto-detect packages
/red-team --repo PATH              # sweep an external repo (e.g. bold, contracts)
/red-team --packages a,b,c         # restrict to specific packages
/red-team --attack-classes X,Y     # restrict to specific attack-class YAMLs
/red-team --dry-run                # list hunters that would run + token estimate, no execution
/red-team --skip-static-analysis   # skip Stage 1 (e.g. when osv/semgrep unavailable)
/red-team --no-validate            # skip Stage 4 (no Codex calls; faster, more noise)
```

## Runtime → Attack-class mapping (hardcoded)

The bundled attack classes and this table were written for the package directories of
Mento's monorepo.

| Package directory | Attack-class YAML(s) |
| ----------------- | -------------------- |
| `indexer-envio/`  | `envio-indexer.yml`  |
| `ui-dashboard/`   | `nextjs-vercel.yml`  |
| `aegis/`          | `nestjs-webhook.yml` |
| `metrics-bridge/` | `nestjs-webhook.yml` |

For external repos, pass `--attack-classes` explicitly. Hardcoding is a deliberate v1 choice; auto-detection from package.json was deferred as YAGNI.

---

## Operating Protocol

Use the runtime's available agent and process tools. Select relevant hunters,
then queue them within its concurrency and spend limits. A hunter count is total
coverage, not a simultaneous spawn requirement. Keep useful independent work in
the parent. When the runtime lets you choose a child's model, choose an allowed
model explicitly. If another model performs hunting, select an available independent family
for validation or disclose the missing independence. Never bypass a runtime
restriction to obtain a second reviewer.

These rules govern every run. Use `[red-team]` labels for progress.

### 1. Pre-flight summary (FIRST line of output)

Before spawning anything:

```text
[red-team] Sweeping {REPO}/{packages}. {N} hunters planned across {M} attack classes. Expected 10–25 min. Progress streams below.
```

### 2. Streaming progress (one line per state transition)

```text
[red-team] static-analysis — started (osv-scanner + semgrep, 3 min budget)
[red-team] static-analysis — completed (0 osv findings, 4 semgrep findings)
[red-team] recon:indexer-envio — started (5 min budget)
[red-team] recon:indexer-envio — completed (architecture doc cached)
[red-team] hunt:indexer-envio:bigint-overflow — started (6 min budget, 8 files in scope)
[red-team] hunt:indexer-envio:bigint-overflow — completed (3 findings)
[red-team] hunt:indexer-envio:rpc-trust — TIMED OUT after 360s — using partial output (1 finding)
[red-team] validate:probe:f3 — CONFIRMED (codex agreed, repro step provided)
[red-team] validate — 7 WARNING+ findings, probe passed → spawning 6 more codex validators
[red-team] validate:f4 — DISPROVED (codex: "this code path is unreachable from external input")
[red-team] dedup — 12 raw → 9 distinct; 6 confirmed, 2 suspected, 1 disproved
[red-team] report — written to .claude/sec-reports/2026-05-22T13-45.md
[red-team] done — 6 confirmed, 2 suspected, 1 disproved, 0 confirmed blockers
```

### 3. Wall-clock budgets (hard, not soft)

| Scope                     | Budget           | What happens at the cap                                      |
| ------------------------- | ---------------- | ------------------------------------------------------------ |
| Static analysis (Stage 1) | **3 min (180s)** | Skip; emit `TIMED OUT — proceeding without`                  |
| Per Recon subagent        | **5 min (300s)** | Skip; hunters get scope_hint only, no recon doc              |
| Per Hunter subagent       | **6 min (360s)** | Skip; use partial output; emit `TIMED OUT`                   |
| Per Validator codex call  | **5 min (300s)** | Skip that finding's validation; tag as `UNCERTAIN` in report |
| Orchestrator total        | **25 min**       | Hard stop; report on whatever has returned                   |

Pass per-stage budget into the prompt so the agent can prioritize.

### 4. Codex pair-spawn (Validate stage uses Codex, not Claude)

Validators run as `codex` CLI calls via `scripts/codex-validate.sh`. This is load-bearing: Claude does Hunt, Codex does Validate. Different model lineage = the multi-model adversarial property Cloudflare's Validate stage depends on. This uses the independent-review pattern described by `/review`, applied per-finding rather than per-PR. The script runs the newest visible Sol model in the Codex model catalog, which the review skill's `scripts/codex-sol-model.py` resolves, so the review skill must be installed next to this one. When that lookup fails, the script exits 70 and starts no codex; it never falls back to the Codex default model.

**Severity gate:** Only WARNING and BLOCKER findings get a Codex validator. NIT findings ship to the report unvalidated. This bounds Codex API cost: realistic runs produce ~10–30 validator calls, not 100+.

### 5. Per-package report sections

The final Markdown report has one section per package and a top-level summary. Findings within each section separate confirmed defects from suspicions and order them by severity. Each finding cites file:line, severity, attack class, hunter ID, and validator verdict (CONFIRMED/DISPROVED/UNCERTAIN/SKIPPED).

---

## Stages

### Stage 0 — Pre-flight

1. Resolve `--repo` (default cwd).
2. Resolve package list (`--packages` flag, or auto-discover by reading pnpm-workspace.yaml / package.json workspaces / falling back to top-level dirs with package.json).
3. Map each package to attack-class YAML(s) via the documented table above; intersect with `--attack-classes` if passed.
4. Expand each (package, attack-class)'s `scope_hints` globs into a concrete file list. Then **apply the attack class's `exclude:` patterns** (if present) to drop files that don't fit the class (e.g. read-only routes excluded from `server-action-auth`). Deduplicate.
5. **Chunk wide scopes.** If the resulting file list exceeds **10 files**, split it into chunks of ~8–10 files. Each chunk becomes its own hunter (e.g. `hunt:indexer-envio:bigint-overflow:1of5`, `:2of5`, …). Cap at **5 chunks per attack class** — if the list would exceed 50 files, prioritize files whose names match the attack class's most-likely-hit pattern (e.g. for `bigint-overflow`, prefer files containing `math`, `swap`, `tradingLimits`, `liquity`, accumulator/snapshot words). Document the truncation in the report. **Why chunked:** a single hunter reading 50 source files burns its 6-min budget on file-reading rather than analysis (observed on the first run).
6. Print the pre-flight line. If `--dry-run`, print the planned hunter table (one row per chunk) and exit.

### Stage 1 — Static analysis

Run both tools in parallel. Both invoke from the **repo root** (not per-package) so they pick up lockfiles and rule defaults correctly. Filter findings to active-package paths at hunter-prompt-construction time.

**osv-scanner** — scans the repo's lockfile(s) for known CVEs in dependencies. Use v2 syntax with explicit lockfile flags and `--output` (mixing status output and JSON on stdout breaks jq parsing).

Build the invocation by checking which lockfiles exist at repo root and passing each as its own `--lockfile`:

```bash
LOCKFILES=()
for f in pnpm-lock.yaml package-lock.json yarn.lock Cargo.lock Pipfile.lock go.sum requirements.txt; do
  [ -f "$REPO/$f" ] && LOCKFILES+=(--lockfile "$REPO/$f")
done

if [ "${#LOCKFILES[@]}" -gt 0 ]; then
  osv-scanner scan source "${LOCKFILES[@]}" \
    --format json \
    --output "$REPO/.claude/sec-recon/static-analysis-osv.json" \
    2>"$REPO/.claude/sec-recon/static-analysis-osv.stderr"
  # Capture the exit status and inspect errors; findings and failed scans differ.
fi
```

Under a command sandbox, `--recursive .` can visit only one directory; explicit `--lockfile` flags are the reliable form.

**semgrep** — pattern-based SAST. Use `--config=auto` to let semgrep pick rules by language detection, plus targeted packs:

```bash
semgrep scan \
  --config=auto \
  --config=p/javascript \
  --config=p/typescript \
  --json --quiet --timeout=180 \
  --output="$REPO/.claude/sec-recon/static-analysis-semgrep.json" \
  "$REPO" 2>/dev/null
```

On a Next.js and strict TypeScript codebase, `p/security-audit + p/nextjs + p/typescript` returned 0 findings — those packs aren't well-tuned for Next.js 16 / TS strict. `--config=auto` + `p/javascript` + `p/typescript` is a better default.

**Filtering findings into hunter prompts:** for each `(package, attack-class, chunk)` the orchestrator filters the JSON to entries whose `path` starts with the chunk's package and the relevant scope. That filtered slice becomes `{{STATIC_ANALYSIS_FINDINGS}}` in the hunter prompt: "Static analysis already found X. Focus on the contextual/semantic stuff it missed."

**Sandbox note:** osv-scanner needs to write to `~/.cache/osv-scanner/`, semgrep needs `~/.semgrep/` and `~/.cache/semgrep/`. Add them to the runtime's write allowlist where it has one. If a required path is denied, use the active runtime's normal approval mechanism for the exact operation. Do not disable the sandbox automatically. Record unavailable coverage and continue independent inspection.

If either tool is missing or fails, log and proceed without that source. Skip the whole stage via `--skip-static-analysis`. This is the cheapest signal source and the cheapest grounding for hunters.

### Stage 2 — Recon (parallel per package)

Spawn one Claude Code subagent per package with `scripts/prompts/recon.md`. Each writes `$REPO/.claude/sec-recon/<package>-<source-sha>.md` — build cmds, trust boundaries, entry points, attack surface, declared dependencies.

**Caching by source SHA** (v2). Compute a stable hash of the package's tracked source tree and skip recon if the cache hits:

```bash
SOURCE_SHA="$(cd "$REPO" && git ls-files "$PACKAGE" | sort | xargs -I{} sha1sum "{}" | sha1sum | cut -c1-12)"
CACHE_PATH="$REPO/.claude/sec-recon/${PACKAGE}-${SOURCE_SHA}.md"

if [ -f "$CACHE_PATH" ]; then
  echo "[red-team] recon:$PACKAGE — cached ($SOURCE_SHA)"
else
  echo "[red-team] recon:$PACKAGE — generating ($SOURCE_SHA)"
  # spawn recon subagent → write to $CACHE_PATH
fi
```

Hunters get `$CACHE_PATH` (sha-suffixed) as `{{RECON_DOC}}`. Stale recons stay on disk indefinitely; the source-sha key means they're orthogonal to whatever's current. Garbage-collect manually with `find $REPO/.claude/sec-recon -name '*.md' -mtime +30 -delete`.

Why caching is worth doing in v2 (not v1): recon is the most-expensive single subagent (about 140k tokens for one web package). When a sweep is re-run after only attack-class YAML edits, regenerating recon is wasteful. After source files change, the SHA changes and recon re-runs.

### Stage 3 — Hunt (parallel per (package, attack-class, chunk))

For each (package, attack-class, chunk) tuple from Stage 0 step 5, spawn one Claude Code subagent with `scripts/prompts/hunter.md`. The hunter receives:

- `{{ATTACK_CLASS}}` — name + description from the YAML
- `{{SCOPE_HINT}}` — human-readable hint ("Mento v2 tradingLimitsState is keyed on bytes32(exchangeId × token)…")
- `{{RECON_DOC}}` — the recon doc for this package
- `{{STATIC_ANALYSIS_FINDINGS}}` — semgrep/osv findings within this package's scope
- `{{FILES}}` — explicit list of file paths for this chunk (already expanded and capped at ~10 files)

Hard rule in the prompt: **read only `{{FILES}}`; do not Glob/Grep for more.** This is the file-scoping mechanism that addresses the subagent context-window concern.

Typical fanout: 3–5 attack classes per package × ~2 chunks (after capping) × 3 packages = **15–30 hunters per full sweep**. Stage 5's dedup step merges duplicate findings across chunks (same file:line ±15).

### Stage 4 — Validate (parallel per WARNING+ finding)

For each finding with severity ≥ WARNING, invoke `scripts/codex-validate.sh` with the finding + relevant code snippet. Codex returns one of: `CONFIRMED` (with repro step), `DISPROVED` (with FP reasoning), or `UNCERTAIN` (insufficient context).

Findings with `--no-validate`, NIT severity, or a failed validator probe skip this stage and are tagged `SKIPPED` in the report.

**Probe one validator before fanning out.** Run `codex-validate.sh` on one finding first. `codex` needs network access and writes launcher state outside the repository. If the probe fails with a sandbox denial, rerun it through the runtime's normal approval mechanism for unsandboxed execution; do not disable the sandbox by other means. Run every later validator through the same approved route as the passing probe. On exit 64, or exit 1 before the script prints its `[codex-validate] running on` line (the renderer could not read the finding), fix that finding's input and probe again. The probe passes only on exit 0 with a `VERDICT:` line; a timeout (exit 124) proves nothing, because an unreachable service hangs every call the same way. On any other result, start no further validators: tag every WARNING+ finding `SKIPPED`, put the script's error in `validator_reasoning`, and add the bracketed probe-failure suffix from the report template to the **Validator:** line. A broken invocation fails every call, and per-finding `UNCERTAIN` tags would hide that: a CLI version that rejects one flag, or an account that rejects the model, fails every validator the same way.

### Stage 5 — Deduplicate and verify evidence

Merge only findings with the same mechanism and affected behavior. Nearby lines
alone do not establish duplication. Preserve separate defects at the same site.

For every finding, record `evidence_status`: `confirmed`, `suspected`, or
`disproved`. The parent must read the relevant source, reachable attack path,
trust boundary, and validator reasoning before marking a finding confirmed.
Agreement between hunters or a severe label is not proof. A validator's answer
is evidence to inspect, not automatic confirmation. Preserve serious unresolved
suspicions in a separate section. Do not discard them because of an invented
score or present them as established vulnerabilities.

Set `surfaced` true only for confirmed findings in the main findings section.
State severity separately. Keep suspected and disproved findings in their named
report sections with the missing evidence or reason. These are review findings;
this skill does not authorize exploitation, edits, or publication.

### Stage 6 — Report

Write **both** Markdown (for humans) and JSON (for queryable downstream consumption) under `$REPO/.claude/sec-reports/`:

```text
.claude/sec-reports/<sweep_id>.md     # human-readable
.claude/sec-reports/<sweep_id>.json   # schema-validated, queryable via jq
```

Where `<sweep_id>` is an ISO-timestamp like `2026-05-22T15-50Z`.

**Markdown** layout:

```markdown
# Red Team: {REPO} — {DATE}

**Sweep:** {N} hunters across {M} attack classes, {P} packages
**Verdict:** {N} blockers, {N} warnings, {N} suggestions
**Validator:** {N} CONFIRMED, {N} DISPROVED, {N} UNCERTAIN, {N} SKIPPED[ — probe failed: exit {CODE}, {first error line}]
**JSON:** `<sweep_id>.json` (schema: `scripts/schema.json`)

---

## {package}

### Confirmed findings

- [file:line] Description (attack class: bigint-overflow; hunter h3; validator: CONFIRMED)
  - Repro: ...
- [file:line] Description (attack class: rpc-trust; hunter h7; validator: CONFIRMED)

<details><summary>Suspected findings — evidence still needed</summary>

- [file:line] Suspected issue and the evidence needed to resolve it.

</details>
```

**JSON** matches `scripts/schema.json` (Draft-07, report contract v2). New reports
require `evidence_status`; legacy v1 reports must not be relabeled as v2 without
reviewing their evidence. Top-level fields: `sweep_id`, `repo`, `date`, `packages[]`, `attack_classes[]`, `hunters_spawned`, `validators_spawned`, `static_analysis{}`, `verdict_counts{}`, `findings[]`. Each finding has: `id` (f-NNN), `severity`, `location` (file:line), `attack_class`, `hunter_id`, `validator_verdict`, `validator_reasoning`, `validator_reproduction`, `evidence_status`, `surfaced` (true only for a confirmed finding), `description`, `exploit_scenario`, `corroborated_by_static_analysis`.

**Schema validation:** after writing the JSON, run a final orchestrator step that validates with `python3 -c "import json, jsonschema; jsonschema.validate(json.load(open('$JSON')), json.load(open('$SCHEMA')))"` (or similar). If validation fails, correct the serialization against the schema without changing findings or evidence. Do not spawn a verifier for a mechanical format correction. One retry; if still invalid, log and proceed with Markdown only.

**Why JSON now (was deferred in v1):** queryable findings let downstream tools (or just `jq`) extract subsets — e.g. `jq '.findings[] | select(.surfaced) | "\(.severity) \(.location)"'`. Trivial to add alongside Markdown. The schema also doubles as a contract for any future hunter prompt template that emits structured JSON natively.

---

## Cost / token usage

| Sweep size                                 | Hunters | Validators | Est. Claude tokens (flat-rate) | Est. Codex API |
| ------------------------------------------ | ------- | ---------- | ------------------------------ | -------------- |
| Single package                             | 3–5     | 5–10       | ~150k                          | ~USD 0.50–2    |
| Three packages (full monorepo)             | 9–15    | 10–30      | ~450k                          | ~USD 2–8       |
| Cross-repo (bold/contracts external sweep) | 5–10    | 10–20      | ~250k                          | ~USD 1–5       |

These are historical estimates, not current billing promises. Confirm the active
provider, model, quota, and authorized budget before additional paid calls. Do
not infer an unlimited agent budget from a subscription.

> **Why USD spelled out (not the dollar sign):** when SKILL.md is loaded by the Skill tool, positional args like `$0`, `$1`, `$2` get substituted into any `$N` literal in the prose. The cost table previously had `$0.50–$2` which rendered as `--dry-run.50–indexer-envio` when invoked with those args. Writing "USD" sidesteps the substitution.

## Limitations (v1)

- No PoC sandbox / compile-and-run validation (Glasswing's PoC primitive deferred to v2).
- No cross-repo Trace stage (defer until we actually sweep multi-repo with shared libs).
- No persistent / scheduled operation (use `/loop` if you want recurring runs).
- Auto-discovery of attack classes from package.json deferred — hardcoded mapping for now.
