/**
 * The order in which `apply` writes the selected items. Pure; no I/O.
 *
 * One run's own writes change other issues' digests, and `apply` skips any
 * issue whose digest differs from the snapshot. So when the write to #A
 * touches #B's digest and both are selected, #B is written first. #A touches
 * #B when:
 *   - #A is a close and #B's snapshot lists #A among its cross-references
 *     (the close changes that reference's state);
 *   - the text #A posts (`comment`, `newBody`, `newTitle`) names #B, which adds
 *     a reference on #B;
 *   - #A's `duplicateOf` is #B.
 * Ties and cycles fall back to issue-number order; in a cycle the later issue
 * is then skipped as `changed`. Every match here errs towards an extra edge: a
 * missed edge can only cause a `changed` skip, never a write.
 *
 * Pure ESM, zero dependencies, Node >= 22.12.
 */

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Issue numbers the item's posted text may link: `#N` in any form, and this repository's issue or PR URLs. */
export function namedNumbers(item, repo) {
  const text = [item.comment, item.newBody, item.newTitle]
    .filter((t) => typeof t === "string")
    .join("\n");
  const out = new Set();
  // `#N` also matches `owner/name#N`; a match for another repository is a
  // harmless extra edge (plan validation refuses such links anyway).
  for (const m of text.matchAll(/#([0-9]{1,10})/g)) out.add(Number(m[1]));
  const [owner, name] = String(repo).split("/");
  const url = new RegExp(
    `github\\.com/${escapeRegExp(owner)}/${escapeRegExp(name)}/(?:issues|pull|pulls)/([0-9]{1,10})`,
    "gi",
  );
  for (const m of text.matchAll(url)) out.add(Number(m[1]));
  return out;
}

/** A reference from issue `number` in this repository; an unknown repository counts as this one. */
const fromThisRepo = (ref, number, repo) =>
  ref.number === number &&
  (ref.repo == null ||
    String(ref.repo).toLowerCase() === String(repo).toLowerCase());

/**
 * `items` are the selected executable plan items; `snapIssues` maps an id to
 * its snapshot issue. Returns the ids in write order.
 */
export function writeOrder(items, snapIssues, repo) {
  const ids = items.map((i) => i.id).sort((a, b) => Number(a) - Number(b));
  const selected = new Set(ids);
  // before.get(A) holds every B that must be written before A.
  const before = new Map(ids.map((id) => [id, new Set()]));
  // referencedBy.get(N) holds every selected B whose snapshot lists issue #N.
  const referencedBy = new Map();
  for (const b of ids) {
    for (const r of snapIssues.get(b)?.links.crossRefs ?? []) {
      if (!fromThisRepo(r, r.number, repo)) continue;
      if (!referencedBy.has(r.number)) referencedBy.set(r.number, new Set());
      referencedBy.get(r.number).add(b);
    }
  }
  for (const a of items) {
    const touched = new Set([...namedNumbers(a, repo)].map(String));
    if (a.duplicateOf !== undefined) touched.add(String(a.duplicateOf));
    if (a.verdict === "close")
      for (const b of referencedBy.get(Number(a.id)) ?? []) touched.add(b);
    for (const b of touched)
      if (b !== a.id && selected.has(b)) before.get(a.id).add(b);
  }
  const order = [];
  const done = new Set();
  const remaining = [...ids];
  while (remaining.length) {
    const ready = remaining.findIndex((id) =>
      [...before.get(id)].every((b) => done.has(b)),
    );
    // In a cycle nothing is ready: take the lowest number left.
    const at = ready === -1 ? 0 : ready;
    const [id] = remaining.splice(at, 1);
    order.push(id);
    done.add(id);
  }
  return order;
}
