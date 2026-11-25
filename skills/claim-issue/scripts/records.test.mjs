import assert from "node:assert/strict";
import { test } from "node:test";

import {
  formatRecord,
  isRunRef,
  isSession,
  parseNumber,
  parseRecord,
  recordsOf,
  sanitizeReason,
  trustedSet,
} from "./records.mjs";

const CLAIM = {
  action: "claim",
  at: "2026-11-16T13:40:00Z",
  expires: "2026-11-19T13:40:00Z",
  run: "https://github.com/o/r/pull/12",
  session: "claude:mac:worktree-foo",
};
const MARKER_LINE =
  '<!-- claim-issue:v1 {"action":"claim","at":"2026-11-16T13:40:00Z","expires":"2026-11-19T13:40:00Z","run":"https://github.com/o/r/pull/12","session":"claude:mac:worktree-foo"} -->';

test("formatRecord writes the spec's canonical marker and prose", () => {
  const body = formatRecord({
    session: CLAIM.session,
    run: CLAIM.run,
    expires: CLAIM.expires,
    at: CLAIM.at,
    action: "claim",
  });
  const [line1, line2] = body.split("\n");
  assert.equal(line1, MARKER_LINE);
  assert.match(
    line2,
    /^\*\*Claimed\*\* by session `claude:mac:worktree-foo`, run `https:\/\/github.com\/o\/r\/pull\/12`, until 2026-11-19T13:40:00Z\./,
  );
});

test("valid claim and release records parse", () => {
  assert.deepEqual(parseRecord(`${MARKER_LINE}\nprose`), CLAIM);
  const rel = {
    action: "release",
    at: "2026-11-17T00:00:00Z",
    session: "s:abc",
    reason: "done",
    claim_at: CLAIM.at,
  };
  assert.deepEqual(parseRecord(formatRecord(rel)), rel);
  const takeover = { ...CLAIM, allow_open_prs: [3, 4] };
  assert.deepEqual(parseRecord(formatRecord(takeover)), takeover);
  assert.match(
    formatRecord(takeover),
    /Deliberate takeover of open PR #3, #4\./,
  );
  // `start` is no longer part of the schema: priority is comment order.
  assert.equal(
    parseRecord(
      MARKER_LINE.replace(
        'worktree-foo"}',
        'worktree-foo","start":"2026-11-15T00:00:00Z"}',
      ),
    ),
    null,
  );
});

test("a marker not on line 1 is not a record", () => {
  assert.equal(parseRecord(`hello\n${MARKER_LINE}`), null);
  assert.equal(parseRecord(` ${MARKER_LINE}`), null);
});

test("wrong prefix, bad JSON, unknown key and wrong type are not records", () => {
  assert.equal(
    parseRecord(MARKER_LINE.replace("claim-issue:v1", "claim-issue:v2")),
    null,
  );
  assert.equal(parseRecord(MARKER_LINE.replace("<!-- ", "<!--")), null);
  assert.equal(parseRecord(MARKER_LINE.replace(" -->", "-->")), null);
  assert.equal(parseRecord(MARKER_LINE.replace('"claim",', '"claim",,')), null);
  assert.equal(
    parseRecord(MARKER_LINE.replace('"action"', '"extra":1,"action"')),
    null,
  );
  assert.equal(
    parseRecord(MARKER_LINE.replace('"2026-11-19T13:40:00Z"', "1700000000")),
    null,
  );
  assert.equal(
    parseRecord(
      MARKER_LINE.replace("2026-11-19T13:40:00Z", "2026-13-19T13:40:00Z"),
    ),
    null,
  );
  assert.equal(
    parseRecord(
      MARKER_LINE.replace(
        '"session":"claude:mac:worktree-foo"',
        '"session":"x"',
      ),
    ),
    null,
  );
  assert.equal(
    parseRecord(MARKER_LINE.replace('"action":"claim"', '"action":"route"')),
    null,
  );
  assert.equal(
    parseRecord(
      MARKER_LINE.replace('"action":"claim"', '"action":"__proto__"'),
    ),
    null,
  );
  assert.equal(
    parseRecord(
      MARKER_LINE.replace(
        'worktree-foo"}',
        'worktree-foo","allow_open_prs":["1"]}',
      ),
    ),
    null,
  );
  assert.ok(
    parseRecord(
      MARKER_LINE.replace(
        'worktree-foo"}',
        'worktree-foo","allow_open_prs":[1]}',
      ),
    ),
  );
  assert.equal(
    parseRecord(MARKER_LINE.replace("{", "[").replace("}", "]")),
    null,
  );
});

test("records count only from trusted authors; a body marker of an untrusted author is ignored", () => {
  const trusted = trustedSet(["Agent-Bot", "octo-owner"]);
  const comments = [
    { author: { login: "mallory" }, body: MARKER_LINE },
    { author: { login: "agent-bot" }, body: MARKER_LINE },
    { author: null, body: MARKER_LINE },
    { author: { login: "OCTO-OWNER" }, body: `quote\n${MARKER_LINE}` },
  ];
  const found = recordsOf(comments, trusted);
  assert.equal(found.length, 1);
  assert.equal(found[0]._index, 1);
});

test("sanitizeReason strips marker ends, mentions, backticks and newlines", () => {
  const out = sanitizeReason(
    "done --> <!-- x --> @someone `rm -rf` \n second line\r\n third\u0000",
  );
  assert.equal(out, "done -- !-- x -- someone rm -rf second line third");
  for (const bad of ["<", ">", "@", "`", "\n"]) assert.ok(!out.includes(bad));
  assert.equal(sanitizeReason("x".repeat(500)).length, 200);
  assert.equal(sanitizeReason(" \n<>@` "), null);
  assert.equal(
    parseRecord(
      formatRecord({
        action: "release",
        at: CLAIM.at,
        session: "s:abc",
        reason: out,
        claim_at: CLAIM.at,
      }),
    ).reason,
    out,
  );
});

test("formatRecord refuses an unsanitised reason", () => {
  assert.throws(() =>
    formatRecord({
      action: "release",
      at: CLAIM.at,
      session: "s:abc",
      reason: "a --> b",
      claim_at: CLAIM.at,
    }),
  );
});

test("session, run and number validators", () => {
  assert.ok(isSession("claude:mac:worktree-foo"));
  for (const bad of ["ab", "-abc", "a b c", "abc`", "a".repeat(101), "abc@x"])
    assert.ok(!isSession(bad), bad);
  for (const ok of [
    "https://github.com/o/r/pull/12",
    "#12",
    "fix-552-race",
    "ci/552-x",
  ])
    assert.ok(isRunRef(ok), ok);
  for (const bad of [
    "https://evil.com/x",
    "http://github.com/o",
    "#0",
    "#12a",
    "-x",
    "a b",
    "https://github.com/o/r?x=`y`",
    "x@y",
  ]) {
    assert.ok(!isRunRef(bad), bad);
  }
  assert.equal(parseNumber("12"), 12);
  for (const bad of [
    "0",
    "012",
    "1e3",
    "-1",
    " 1",
    "12 ",
    "99999999999",
    "2147483648",
  ])
    assert.equal(parseNumber(bad), null, bad);
});
