# agents

Mento Protocol tooling for automated and human-in-the-loop repository agents.
A pnpm workspace; each package under `packages/*` publishes independently to
npm as `@mento-protocol/<name>`.

## Packages

- [`packages/issues`](packages/issues/README.md) — `@mento-protocol/issues`.
  GitHub ref-backed claims (a compare-and-swap mutex with an opt-in lease), a
  bounded `gh` runner, and procedural-marker byte contracts. Ships the
  `mento-issues` CLI.

## Development

```bash
pnpm install
pnpm test          # pnpm -r test — runs every package's test suite
trunk check --all  # lint (or: pnpm lint)
trunk fmt          # format (or: pnpm format)
```

Each package's own README documents its usage; run its suite directly with
`pnpm --filter <package-name> test` during development.

## Publishing a package

Publishing is two steps, matching this repository's trusted-publishing setup:

1. **First release only (operator, manual).** From the merged `main`, an
   operator with a 2FA-backed npm account runs
   `npm publish --workspace packages/<name> --access public`, then enables
   [npm trusted publishing](https://docs.npmjs.com/trusted-publishers) for the
   package on npmjs.com, pointing at this repository
   (`mento-protocol/agents`) and `.github/workflows/publish.yml`. This is a
   precondition for any consumer that depends on the published version.
2. **Every release (including the first, redundantly).** Push a tag shaped
   `<package-name>@<version>` — today only `@mento-protocol/issues@*`, which is
   the one tag pattern `.github/workflows/publish.yml` triggers on — once the
   version bump is on `main`. A second package needs its own trigger pattern
   and its own filtered test and publish steps in that workflow.

   The workflow checks out with `persist-credentials: false`, installs with
   `pnpm install --frozen-lockfile`, installs `npm@11.5.1` globally (trusted
   publishing needs a recent npm), **verifies the tag matches `package.json`,
   then runs the package's test suite**, and finally publishes via npm trusted
   publishing (OIDC — no `NODE_AUTH_TOKEN`, and provenance is generated
   automatically). It skips publishing without failing when the exact version
   already exists on the registry, so the operator's manual first publish and
   the tag-triggered workflow never conflict.

No package here declares runtime `dependencies`. A consumer that cannot add a
workspace dependency runs a package's CLI through `dlx`, naming the binary
after `dlx` and the pinned spec through `--package`:

```bash
pnpm --config.ignore-scripts=true --package=@mento-protocol/issues@0.1.0 \
  dlx mento-issues <command> [...args]
```

The shorter `pnpm dlx <spec> <binary>` form does not work: pnpm passes the
binary name to the CLI as its first positional argument.
