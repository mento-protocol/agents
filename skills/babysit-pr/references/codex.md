# Babysit PR — Codex adapter

The ledger, fixing rules, and watch policy are in `../SKILL.md`. The runtime-neutral
poller mechanics are in `live-watch.md`. This file maps that watch onto Codex's tools.

## The bundled poller — Codex mapping

Codex has no Monitor and no TaskStop. A long shell command returns a session after its
yield window, and the caller waits on that session until the process exits. That is the only
watch mode here: there is no separate background form and no separate subagent case.

1. Start one poller with a slice of 300 seconds or the budget that remains, whichever is
   smaller: `BABYSIT_DEADLINE_SECONDS=<slice> ~/.agents/skills/babysit-pr/babysit-prs.sh <PR numbers>`.
2. Keep waiting on that same session until the process exits. Never start a second poller
   while one is still running.
3. Bound the wait at the deadline plus the one-pass cushion: 300 seconds for one PR, and
   300 seconds more for each further PR in the watch. A poller still running after that bound
   has no verdict: stop the process and report the watch as unknown.
4. Re-invoke with a fresh slice as `live-watch.md` describes for a foreground watch, until every
   PR is terminal or the disclosed budget ends.
