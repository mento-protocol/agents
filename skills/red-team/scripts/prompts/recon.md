# Recon prompt — per-package architecture document

You are producing a **security-focused architecture document** for the package below. Hunters will use this as their grounding context, so prioritize the things a security reviewer needs over a generic README.

## Inputs

- `{{PACKAGE_PATH}}` — absolute path to the package root
- `{{PACKAGE_NAME}}` — short name (`indexer-envio`, `ui-dashboard`, `aegis`, etc.)
- `{{STATIC_ANALYSIS_FINDINGS}}` — JSON of any osv-scanner / semgrep findings within this package (may be empty)

## What to produce

A Markdown document with these exact sections — concise, bulleted, no prose padding:

### 1. Purpose

One sentence: what this package does, who calls it, where it runs.

### 2. Build / run / entry points

- Build command(s) — `pnpm <task>`, `cargo build`, etc.
- Start command(s) — `pnpm start`, `node dist/x`, GAE handler entry, Vercel route
- Top-level entry points — the file(s) that get invoked first when the process starts (e.g. `src/EventHandlers.ts` for Envio indexer, `src/main.ts` for NestJS, `src/middleware.ts` + `src/app/**/route.ts` for Next.js)
- Background loops / event listeners (Envio handlers, cron jobs, message-bus subscribers)

### 3. Trust boundaries

List every input source and whether the data is trusted, semi-trusted, or untrusted. Be specific:

- **Untrusted**: HTTP request bodies, query strings, URL params, cookies (except auth-issued ones), webhook payloads from external services, user-uploaded files
- **Semi-trusted**: on-chain events (the chain itself is trusted but the contract you're indexing may be hostile or compromised), RPC responses (the node may lie), filesystem state from a previous run
- **Trusted**: env vars (assuming Vercel/GCP secret management), in-process derived state, generated TS types, this package's own committed code

Identify the **specific code locations** where untrusted/semi-trusted data crosses INTO trusted code paths. These are the attack surface.

### 4. External dependencies

- Production dependencies with security relevance (web frameworks, ORMs, parsers, crypto libs, RPC clients, template engines, markdown renderers, HTML sanitizers). Cite version pins.
- Whether the package uses any of: raw SQL (parameterization?), dynamic-code-execution primitives (eval / the JS Function constructor / the `vm` module), child_process, file uploads, deserialization (YAML, msgpack, custom binary).

### 5. Secrets handled

What credentials does this package touch?
- API keys (Grafana, Slack, Discord, Codex, Anthropic, Sentry, Upstash, Vercel Blob)
- Service-account JSON / OAuth tokens
- Database passwords / connection strings
- Webhook URLs (treat as bearer tokens)

For each: where it's read from, where it could leak (logs, error messages, response bodies, client bundle).

### 6. Attack surface inventory

Map of (entry point) → (downstream state mutation / external call). This is the thing a hunter looks at to know what to check.

Example for `aegis/`:
- Slack interactive webhook (POST `/slack/actions`) → DB write `Annotation`, external HTTP `slack.com/api/chat.postMessage`
- Grafana alertmanager webhook (POST `/alerts`) → Discord/Slack/VictorOps webhook URL fan-out
- Cron job `everyMinute` → Grafana API `GET /api/alerts` (read-only)

### 7. Known footguns

Any quirks from memory or recent PRs that bias the attack-class hunt:
- v3 CDP reorg sensitivity around redemptions
- Mento bold-fork divergences (silent BoldDebtUpdated, rebalance-redemption conflation)
- Vercel ignoreCommand first-push race
- Whatever else is package-specific

### 8. Static-analysis findings summary

Echo the `{{STATIC_ANALYSIS_FINDINGS}}` count by severity. Group by rule ID. Don't re-paste each finding — hunters will get the raw JSON separately.

## Hard rules

- **Read at least these files**: `package.json`, `tsconfig.json` (if present), the top-level entry file(s), `src/**/index.ts`, any `routes.ts` / `app.module.ts` / `EventHandlers.ts`. After that, sample 5–10 representative files per major directory.
- Do NOT read every file. Use the directory tree + spot-reads to characterize.
- Be specific about file paths and line numbers when you cite trust-boundary crossings.
- Do NOT speculate about vulnerabilities — that's the hunter's job. Only describe the surface.
- Document length target: 400–800 words. Anything longer is wasted hunter context.

Output the architecture doc as raw Markdown. Do not wrap it in code fences.
