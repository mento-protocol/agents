# Babysit PR — Claude Code adapter

The ledger, fixing rules, and watch policy are in `../SKILL.md`. The runtime-neutral
poller mechanics are in `live-watch.md`. This file maps that watch onto Claude Code's
tools: Monitor to supervise the poller, a background Bash task with `tail -f` for a
longer watch, and TaskStop to end a background task you started. Do not duplicate the
shared workflow here.

## The bundled poller — Claude Code mapping

```text
Monitor:
  description: "Babysit PR <number(s)>"
  timeout_ms: 1800000   # Monitor's maximum
  command: BABYSIT_DEADLINE_SECONDS=<disclosed budget, capped at 1500> ~/.agents/skills/babysit-pr/babysit-prs.sh <PR_NUMBER>
```

This is the Claude Code mapping of `live-watch.md`'s three supervision rules: the poller's
deadline is the budget still disclosed, capped at the margin that leaves the supervisor room for
one pass — 1500s for a single PR inside Monitor's 1800000 ms maximum. A 10-minute watch passes
600, not the cap.

The 300s left between that 1500s deadline and Monitor's 1800s holds the one-pass cushion
`live-watch.md` describes for a single PR. For several PRs, or any watch you expect to renew,
prefer the background form below — the supervisor's expiry ends the tail there, never the poller.

For a disclosed budget past that margin, run the poller as a background Bash task
with `BABYSIT_DEADLINE_SECONDS` set to the budget that remains, and point Monitor at the task's
output file (`tail -n +1 -f <output file>`). Monitor still expires every 30 minutes; re-arm it the
same way, from the start of the file, and ignore the events you already acted on. Never re-arm with
`tail -n 0 -f`: it seeks to the end and drops whatever the poller wrote while no Monitor was
attached. Re-arming the tail continues the budget already disclosed — extending the budget itself
is the user's call, as `DEADLINE` in `live-watch.md` says. A background task can also be killed
under memory pressure, so check the PR state before reporting that a watch is still running.

**Inside a subagent, poll in the foreground.** The background form above does not apply there.
Run the poller as a foreground Bash call with `BABYSIT_DEADLINE_SECONDS` set to 300 or the
budget that remains, whichever is smaller, inside a 600000 ms call timeout — the same one-pass
cushion the Monitor mapping above uses — and follow the re-invocation rules in `live-watch.md`.
A Bash call cannot run longer than 600000 ms, so that cushion cannot grow with the PR count:
give each call one PR, and take the watched PRs in turn.
A worker that parks on a background poller is not woken again and needs a resume from its parent.
