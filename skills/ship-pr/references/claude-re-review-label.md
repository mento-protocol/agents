# Claude re-review label

This file owns the rule; `publish.md`, `babysit-pr` and `address-feedback` point here.
It applies where the repository's Claude review workflow (under `.github/workflows/`)
lists `labeled`, runs on the label `re-review`, and removes that label when its run
starts. There a push is not reviewed again. Below, `<review workflow>` is that
workflow's file name and `Claude Review` stands for its run name.

- Add the label (`gh pr edit <N> --add-label re-review`) **once per head**, after a push
  that fixes a [P1] or [P2] finding from any reviewer, or that changes behaviour beyond what
  the last Claude review saw. Never for [P3] or nit fixes, docs, a PR description, or
  merging the base branch in, except in the conflict case of the bullet below (a PR
  opened, marked ready or reopened while it conflicted).
- The labeled run reviews the PR head at that moment; bind its summary like any
  `pull_request` run. A head without a fresh Claude summary is not a missing sign-off
  there: no gate requires one.
- While the label is on the PR, a review is queued or about to start: do not add it again.
  If the label is still there and no `Claude Review` run for the PR is queued or in progress
  (`gh run list --branch <head> --workflow <review workflow>`), remove it and add it once more.
- After any push, if a `Claude Review` run for the PR has not started (status `queued`,
  `waiting` or `pending` in `gh run list --branch <head> --workflow <review workflow>
--json status,headSha`) and its `headSha` differs from the PR's new head, add the label
  once for the new head, removing it first if it is still on, even when the push alone
  would not earn a re-review. The push does not cancel that stale run, and CI
  cancels it unreviewed once the head has moved; the new labeled run replaces it in the
  same concurrency group.
- A PR that is opened, marked ready or reopened while it conflicts with its base gets no
  automatic Claude review: GitHub starts no `pull_request` workflow while a PR has a merge
  conflict, and a push is not one of the review's triggers. After the push that resolves
  the conflict, add the label once for that head, also when that push only merges the base
  branch in, unless `gh run list --branch <head> --workflow <review workflow> --json
conclusion,headSha` already shows a run with conclusion `success`. A `skipped` or
  `cancelled` run reviewed nothing.
- Prefer the label to an on-demand `@claude review` comment there when the repository's
  on-demand workflow is narrower, for example when it accepts only some commenters or
  binds to the default branch's commit instead of the PR head. Read its workflow file to
  tell (babysit-pr `references/live-watch.md`).
