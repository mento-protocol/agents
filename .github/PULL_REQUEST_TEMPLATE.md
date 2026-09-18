<!-- markdownlint-disable MD041 -->

## tl;dr

- [Two to four plain sentences: who had which problem, what changes, what to expect after merge. About 60 words, no identifiers or file paths.]

## The Problem

- [The problem, user impact, or maintenance risk this PR addresses. One line per bullet, at most three.]

## The Solution

- [How this PR solves it, in plain English. One line per bullet, at most five.]

## Validation

- [One line per check on one named head. Group passes: `pnpm test` 42 ✓, `trunk check` ✓. Skipped, failed, or not-proven items each get their own line.]

## Deferrals

- [One line per linked issue for work knowingly left undone, or `None`.]

## Ship Checklist

- [ ] PR title is a [Conventional Commits](https://www.conventionalcommits.org/) header, `type: summary` or `type(scope): summary`, as `commitlint.config.mjs` enforces for commits
- [ ] Performed a self-review of my own changes
- [ ] `node scripts/validate-skills.mjs` and the affected test suites pass
- [ ] Nothing in the diff breaks the public-readership rules in `AGENTS.md`
- [ ] Body is about 250 words, 400 at most, excluding this checklist
