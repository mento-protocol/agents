import assert from "node:assert/strict";
import { test } from "node:test";

import { callerView, claimState } from "./state.mjs";

const NOW = Date.parse("2026-11-16T12:00:00Z");
let index = 0;
// `_posted` is the comment's server time; it defaults to the record's `at`.
const claim = (session, at, expires, more = {}) => ({
  action: "claim",
  at,
  expires,
  session,
  run: "#9",
  _index: index++,
  _posted: at,
  ...more,
});
const release = (session, at, claimAt) => ({
  action: "release",
  at,
  session,
  reason: "done",
  claim_at: claimAt,
});

test("no records: free", () => {
  const s = claimState([], NOW);
  assert.equal(s.winner, null);
  assert.equal(callerView(s, "me:abc").label, "free");
});

test("a live claim holds; the caller's own is mine", () => {
  const s = claimState(
    [claim("a:one", "2026-11-16T10:00:00Z", "2026-11-17T10:00:00Z")],
    NOW,
  );
  assert.equal(s.winner.session, "a:one");
  assert.deepEqual(callerView(s, "a:one"), { label: "mine", entitled: true });
  assert.deepEqual(callerView(s, "b:two"), { label: "held", entitled: false });
});

test("an expired claim does not hold and is reported as expired", () => {
  const s = claimState(
    [claim("a:one", "2026-11-10T10:00:00Z", "2026-11-13T10:00:00Z")],
    NOW,
  );
  assert.equal(s.winner, null);
  assert.equal(s.expired.length, 1);
});

test("a release naming the claim's at ends it; another session's release does not", () => {
  const c = claim("a:one", "2026-11-16T10:00:00Z", "2026-11-17T10:00:00Z");
  assert.equal(
    claimState([c, release("b:two", "2026-11-16T11:00:00Z", c.at)], NOW).winner
      .session,
    "a:one",
  );
  assert.equal(
    claimState(
      [c, release("a:one", "2026-11-16T11:00:00Z", "2026-11-16T09:00:00Z")],
      NOW,
    ).winner.session,
    "a:one",
  );
  const s = claimState(
    [c, release("a:one", "2026-11-16T11:00:00Z", c.at)],
    NOW,
  );
  assert.equal(s.winner, null);
  assert.equal(s.expired.length, 0);
});

test("a renewal keeps the chain start; a release of any claim in the chain ends it", () => {
  const first = claim("a:one", "2026-11-14T10:00:00Z", "2026-11-17T09:00:00Z");
  const renewal = claim(
    "a:one",
    "2026-11-16T09:00:00Z",
    "2026-11-19T09:00:00Z",
    { start: first.at },
  );
  const s = claimState([first, renewal], NOW);
  assert.equal(s.winner.start, first.at);
  assert.equal(s.winner.latest.at, renewal.at);
  assert.equal(
    claimState(
      [first, renewal, release("a:one", "2026-11-16T11:00:00Z", first.at)],
      NOW,
    ).winner,
    null,
  );
});

test("a claim after the session's expired claim starts a new chain", () => {
  const old = claim("a:one", "2026-11-10T10:00:00Z", "2026-11-11T10:00:00Z");
  const fresh = claim("a:one", "2026-11-16T09:00:00Z", "2026-11-19T09:00:00Z");
  const s = claimState([old, fresh], NOW);
  assert.equal(s.winner.start, fresh.at);
  // A release that names the old chain does not end the new one.
  assert.equal(
    claimState(
      [old, fresh, release("a:one", "2026-11-16T10:00:00Z", old.at)],
      NOW,
    ).winner.start,
    fresh.at,
  );
});

test("contested: the earlier first claim comment wins, even after the later one renews", () => {
  const a1 = claim("a:one", "2026-11-15T08:00:00Z", "2026-11-16T09:00:00Z");
  const b = claim("b:two", "2026-11-16T08:00:00Z", "2026-11-19T08:00:00Z");
  const a2 = claim("a:one", "2026-11-16T08:30:00Z", "2026-11-19T08:30:00Z");
  const s = claimState([a1, b, a2], NOW);
  assert.equal(s.contested, true);
  assert.equal(s.winner.session, "a:one");
  assert.deepEqual(callerView(s, "a:one"), {
    label: "contested",
    entitled: true,
  });
  assert.deepEqual(callerView(s, "b:two"), {
    label: "contested",
    entitled: false,
  });
});

test("priority is comment order, not the client timestamp", () => {
  const a = claim("a:one", "2026-11-16T11:00:00Z", "2026-11-19T11:00:00Z");
  const b = claim("b:two", "2026-11-16T10:00:00Z", "2026-11-19T10:00:00Z"); // posted later, earlier `at`
  const s = claimState([a, b], NOW);
  assert.equal(s.winner.session, "a:one");
  assert.equal(s.contested, true);
});

test("[B expired, A claim, B claim]: A wins although B's new claim carries an earlier at", () => {
  const b1 = claim("b:two", "2026-11-10T10:00:00Z", "2026-11-11T10:00:00Z");
  const a = claim("a:one", "2026-11-16T10:00:00Z", "2026-11-19T10:00:00Z");
  const b2 = claim("b:two", "2026-11-16T09:00:00Z", "2026-11-19T09:00:00Z");
  const s = claimState([b1, a, b2], NOW);
  assert.equal(s.winner.session, "a:one");
  assert.deepEqual(
    s.live.map((c) => c.session),
    ["a:one", "b:two"],
  );
});

test("a renewal that GitHub received after the claim expired starts a new chain behind the rival", () => {
  const NOW_LATE = Date.parse("2026-11-16T12:40:00Z");
  const a1 = claim("a:one", "2026-11-16T10:00:00Z", "2026-11-16T12:00:00Z");
  const b = claim("b:two", "2026-11-16T12:30:00Z", "2026-11-19T12:30:00Z");
  // A built the renewal before its claim expired; the post landed at 12:31.
  const a2 = claim("a:one", "2026-11-16T11:59:00Z", "2026-11-19T11:59:00Z", {
    _posted: "2026-11-16T12:31:00Z",
  });
  const s = claimState([a1, b, a2], NOW_LATE);
  assert.equal(s.winner.session, "b:two");
  assert.deepEqual(
    s.live.map((c) => [c.session, c.start]),
    [
      ["b:two", b.at],
      ["a:one", a2.at],
    ],
  );
  // Without a valid server time, a claim never renews.
  const a3 = claim("a:one", "2026-11-16T11:00:00Z", "2026-11-19T11:00:00Z", {
    _posted: "",
  });
  assert.equal(claimState([a1, a3], NOW).live[0].start, a3.at);
});

test("equal starts break by comment order", () => {
  const b = claim("b:two", "2026-11-16T08:00:00Z", "2026-11-19T08:00:00Z");
  const a = claim("a:one", "2026-11-16T08:00:00Z", "2026-11-19T08:00:00Z");
  assert.equal(claimState([b, a], NOW).winner.session, "b:two");
});
