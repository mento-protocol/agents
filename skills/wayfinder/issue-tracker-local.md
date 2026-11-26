# Issue tracker: Local Markdown

Issues and specs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The spec is `.scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a single combined tickets file
- Triage state is recorded as a `Status:` line near the top of each issue file, using one of the triage role strings `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, or `wontfix`
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `.scratch/<effort>/map.md` (the Notes / Decisions-so-far / Fog body). Initialize it with `Status: open`.
- **Child ticket**: `.scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`, with the question in the body. A `Type:` line records the ticket type (`research`/`prototype`/`grilling`/`task`). Initialize each child with `Status: open`. The status values are `open` (unclaimed), `claimed` (still open, owned by a session), and `resolved` (closed).
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked when every file it lists is `resolved`.
- **Frontier**: scan `.scratch/<effort>/issues/` for files with `Status: open` whose blockers are all `resolved`; first by number wins. `claimed` children are unfinished but excluded from selection. A missing or unknown status does not establish a takeable ticket; inspect and repair it before selection.
- **Claim**: acquire the shared session lock defined in `wayfinder/SKILL.md` and re-read the ticket. Set `Status: claimed` before work. Record `Claimed by:` with the session token, `Claimed at:` with UTC time, and `Claim process:` with hostname, PID, and process start time. Only the lock-owning coordinator may modify tracker files.
- **Release / recover**: on orderly exit, reset the coordinator's unfinished tickets to `Status: open`, remove their claim fields, and append a stop note under `## Comments`. After interruption, the human selects one recovery coordinator and confirms the old writers stopped, as defined by the session coordination rules. Only after that coordinator acquires the shared lock may it reset abandoned claims. Preserve existing work. Unknown ownership prevents automatic recovery; timestamps alone do not permit it.
- **Resolve**: while holding the shared session lock, append the answer under an `## Answer` heading, set `Status: resolved`, then re-read `map.md` and append a context pointer (gist + link) to Decisions-so-far. Serialize these updates; research workers return results without writing `map.md`.
- **Out of scope**: append the reason under `## Answer`, set `Status: resolved`, and link the child only from the map's Out of scope section.
- **Complete map**: re-read every child and `map.md`. When every child is `resolved` and no fog remains, set the map's `Status: resolved` and hand off its Destination and decision index. A `claimed` child or an unknown status prevents completion.
