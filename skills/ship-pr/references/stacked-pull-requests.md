# Stacked pull requests

Runtime-neutral rules for a chain of dependent PRs in any repository. A
repository may keep its own, more detailed stack runbook; read it first and
prefer it where the two differ.

## When to stack

Stack only when one reviewable change depends on another. Two or three layers
is the normal size. Each layer needs its own problem, tests, and docs, and a
diff a reviewer can read alone. Independent work stays in independent PRs.
Large line counts alone do not justify a split.

## Two bases per layer

- **Diff base:** the immediate parent branch (`baseRefName`). Use it for
  changed-file checks, scope baselines, and review.
- **Protection base:** the stack target, usually the default branch. Required
  checks and branch protection come from it.

Read stack membership from GitHub. A PR body, a branch name, or a parent
branch proves nothing about native membership.

## Publish and register

1. Publish every layer through the `ship-pr` skill, bottom first, each with the
   normal body and its own validation evidence, each with its diff base as
   the PR base.
2. Register the chain as a native stack, bottom to top, with explicit PR
   numbers. Never let commit-based creation infer PR boundaries:

   ```sh
   gh api -X POST repos/{owner}/{repo}/stacks \
     -H "X-GitHub-Api-Version: 2026-03-10" \
     --input - <<'EOF'
   {"pull_requests": [<bottom>, <next>, <top>]}
   EOF
   ```

   Read it back with `gh api repos/{owner}/{repo}/stacks/{stack_number}` or
   `gh api repos/{owner}/{repo}/pulls/{n} --jq .stack`. Append later layers
   with `POST .../stacks/{stack_number}/add`. Remove the unmerged layers with
   `POST .../stacks/{stack_number}/unstack`, which dissolves the stack when
   none remain. The feature is a public preview; check the current API
   reference when a call fails.

3. Verify each layer has its required CI after registration. A child opened
   before registration may not get main-filtered workflows retroactively.
4. Hand the ordered set to `babysit-pr`. A successful registration is not
   readiness.

If native creation is unavailable, keep the PRs as an ordinary dependent
chain and say so.

## Watch

Watch every open layer, not only the bottom. A parent fix, base change, or
merge revokes every dependent ready verdict; re-read each head and base and
repeat the affected checks. Never `gh stack sync`, amend, or force-push while
watching. Merge an updated parent into a published child with a merge commit
when the chain is ordinary; a native chain must stay linear.

A review fix on a lower layer that touches a line every layer edits (a size
baseline row, a version field, a changelog entry) makes the native rebase of
every higher layer conflict at merge time, and that failure is silent. Keep
fixes off shared lines where the finding allows it. When such a fix lands
anyway, rebase the higher layers onto the new parent head at once, bottom to
top, each with its gates and one `--force-with-lease=<branch>:<old-head>`
push, only after the user approves those pushes; then the merges rebase
cleanly.

## Merge

Merge only the bottommost unmerged layer, one at a time, with the user's
explicit approval for that PR. Native merging of an upper layer also merges
every unmerged layer below it, so never merge from the middle. Immediately
before the merge, read the membership back and confirm the selected PR is
still bottommost.

After each merge, verify every open layer's base and head, not only the next
one. GitHub retargets and rebases the children, but a child can be retargeted
without a completed rebase, and a rebase that hits a conflict in an upper
layer can fail silently, which leaves that layer on its old history and in
conflict with its rebased parent. A retarget alone proves nothing. Compare
ancestry (`git merge-base --is-ancestor`) and mergeability, check each replay
with `git range-diff`, and require fresh CI on the new head before calling it
ready. Recover a failed layer by replaying its commits onto the rebased parent
in a new local branch, resolving conflicts, validating, and publishing with
one exact old-head lease (`git push --force-with-lease=<branch>:<old-head>`)
only after the user approves that push; a merge commit would not survive the
next native rebase.

## Ordinary (non-native) chains

GitHub retargets a dependent PR to the default branch only when the merged
PR's head branch is deleted. So delete the head branch on every merge
(`gh pr merge N --merge --delete-branch`, or the repository setting
"Automatically delete head branches"), and after every merge retarget the next
PR yourself (`gh pr edit N --base main`) instead of relying on the deletion.
Before every merge confirm the base is the default branch. A PR whose base is
a merged, undeleted branch merges into that stale branch and its work never
reaches main; recover by opening one PR from the highest merged head branch
to the default branch, which contains every merged level.

A squash merge of a stacked PR rolls up everything in its branch, including a
child already squash-merged into it. Check what landed with
`git show <merge-sha> --stat` before treating later layers as unchanged.

## Hand-back

Say in the report which mechanism the stack uses, the merge order, that only
the bottom layer is to be merged, and what the user must do on each merge.
