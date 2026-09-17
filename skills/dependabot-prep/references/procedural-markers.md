# Procedural markers

Use this byte contract with SKILL.md for every top-level response, review reply
and preparation-summary comment, in every repository, with or without claims.
Only the `claim` field is conditional. The executable form of this contract is
the claim command's `markers` group: the policy's `coordination.claims.command`
followed by `markers summary --input <job.json>`, by
`markers build --input <job.json> [--out <body.txt>]`, or by
`markers verify --input <check.json>`. With the Mento command, that first form
reads `pnpm dependabot:claim -- markers summary --input <job.json>`. The
`@mento-protocol/issues/markers` subpath is the same contract and applies only
where the package is an installed dependency.
`fixtures/comment-marker-vectors.json` is the byte authority for cross-runtime
encoding. Run `node --test scripts/comment-marker-vectors.test.mjs` after any
change here.

Paths such as `scripts/` and `fixtures/` are relative to the skill root, not to
this reference directory or the candidate repository.

## Encodings

Root ID. Fetch the original issue comment or review comment through a live API
surface that exposes its REST database ID and body. Require an integer from 1
through 9,007,199,254,740,991. Encode it as base-10 ASCII digits with no sign and
no leading zero, then hash those bytes for `root-id-sha256`. Never hash a GraphQL
node ID, review-thread ID, URL or string-form ID. A missing, string, fractional,
zero, negative or unsafe integer blocks the response.

Root body. Take `root-body-sha256` from the exact current decoded API body
string. Require only valid Unicode scalar values. Re-encode the string directly
as UTF-8 and hash those bytes. Do not normalize Unicode, convert line endings,
trim whitespace, render Markdown, decode HTML or append a newline. Read the same
root again after posting and recompute the digest from the same API field.

Operator. Authenticate the operator through the live API immediately before
posting. Require an integer ID from 1 through 9,007,199,254,740,991, exact type
`User`, and an ASCII login of 1 through 39 characters: letters, digits and single
hyphens, starting and ending with a letter or digit. Reject consecutive hyphens.
Build these exact ASCII bytes in this fixed key order and with no whitespace:

`{"id":<base-10 ID>,"login":"<exact login>","type":"User"}`

Hash those bytes for `operator-sha256`. Do not depend on map iteration order or a
runtime serializer. A host identity that cannot satisfy this grammar cannot post
a portable procedural response.

Visible body. Use valid Unicode scalar values, UTF-8, LF line endings and no
trailing spaces or tabs. Do not normalize it. Hash those exact bytes for
`visible-body-sha256`.

Claim token. 40 lowercase hex characters: the claim ref's current LOCK oid, as
printed by the claim command. The token in a posted marker is the token current
at post time; a later renew rotates it and does not invalidate that marker.

## Comment and reply grammars

Build the marker as one ASCII line, with the field order shown and exactly one
ASCII space between tokens, including before `-->`. Emit lowercase SHA-256 hex.
Build the submitted body as the exact visible-body bytes, two LF bytes, then the
marker bytes. Do not append a final newline.

The marker revision is the policy's `markers.revision`, or `claims.markerRevision`
when `markers.revision` is absent; `v2` is the default. Use v1 when repository
policy prescribes no claims, or when that revision is `v1`:

`<!-- dependabot-prep-comment:v1 root-id-sha256=<64hex> root-body-sha256=<64hex> head=<40 lowercase hex> visible-body-sha256=<64hex> operator-sha256=<64hex> decision=<fixed|wont-fix> -->`

`<!-- dependabot-prep-reply:v1 ... -->` carries the same fields on a review reply.

Use v2 when repository policy prescribes claims and that revision is `v2`:

`<!-- dependabot-prep-comment:v2 root-id-sha256=<64hex> root-body-sha256=<64hex> head=<40 lowercase hex> visible-body-sha256=<64hex> operator-sha256=<64hex> decision=<fixed|wont-fix> claim=<40hex> -->`

`<!-- dependabot-prep-reply:v2 ... -->` carries the same fields on a review reply.

`claim` is appended after `decision`, so the v2 field order is the v1 order plus
one field; the schema token differs, so a reader that matches `:v1` exactly does
not discover a v2 marker. The schema token is the gate: `claim` is required for a `:v2` schema and forbidden for a
`:v1` schema.

## Summary comment

The repository's configured summary marker — `reporting.prCommentMarker`, or
`<!-- dependabot-prep:summary:v1 -->` when policy names none — stays the
discovery token for the one summary comment per author login per PR. Keep it
unchanged, on the comment's first line.

When policy prescribes claims and the marker revision is `v2`, it also names a
claim-marker schema (`reporting.prCommentClaimMarkerSchema`). Add that line on
its own line immediately after the discovery marker:

`<!-- <claim-marker schema> pr=<decimal> claim=<40hex> run-sha256=<64hex> operator-sha256=<64hex> [supersedes=<40hex>] -->`

For example, with the Mento schema:

`<!-- mento-dependabot-preparation:v2 pr=872 claim=<40hex> run-sha256=<64hex> operator-sha256=<64hex> -->`

`markers summary` prints one JSON document on stdout with `v1Line`
(`<!-- mento-dependabot-preparation:v1 -->`, the Mento discovery marker),
`v2Line` (the claim line) and `block` (both, joined by one LF); with
`--out <path>` it also writes `block` to that file. It does not read
`reporting.prCommentMarker`. When the configured discovery marker is a different
line, keep the configured marker first and use `v2Line` alone.

A marker revision of `v1`, and a repository that prescribes no claims, keep the
discovery marker alone.

`pr` is decimal with no leading zero. `run-sha256` is `sha256(utf8(<owner run
id>))` and is provenance only: it records which run last wrote the body. The
comment's author login decides edit against post — a same-login run edits its own
summary comment in place. `supersedes` carries the prior owner's claim token —
the LOCK oid the takeover superseded — is the last field, and appears only on a
cross-login takeover, whose visible body cites the superseded comment's URL.
Keeping the v1 discovery line first means an earlier skill revision still finds
and edits the same comment, so a rollback creates no duplicate summary.
