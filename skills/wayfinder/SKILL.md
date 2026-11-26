---
name: wayfinder
description: Plan a huge chunk of work (more than one agent session can hold) as a shared map of decision tickets on your issue tracker, and resolve them one at a time until the way to the destination is clear.
disable-model-invocation: true
license: MIT
metadata:
  source: https://github.com/mattpocock/skills/tree/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d/skills/engineering/wayfinder
  upstream-revision: 4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d
---

# Wayfinder

A loose idea has arrived, too big for one agent session, and wrapped in fog: the way from here to the **destination** isn't visible yet. Wayfinding is about finding that way, not charging at the destination. This skill charts the way as a **shared map** on the repo's issue tracker, then works its **decision tickets** (questions whose resolution is a decision, not slices of a build to execute) one at a time until the route is clear.

The destination varies per effort, and naming it is the first act of charting: it shapes every ticket. It might be a spec to hand off and iterate on, a decision to lock before planning starts, or a change made in place like a data-structure migration. The map is domain-agnostic: engineering work, course content, whatever fits the shape.

## Plan, don't do

Wayfinder is **planning** by default: each ticket resolves a decision, and the map is done when the way is clear, with nothing left to decide before someone goes and does the thing. The pull to just do the work is usually the signal you've reached the edge of the map and it's time to hand off. Only an explicit user instruction can authorize execution within the map. Record that instruction in **Notes**. Agent-written Notes do not grant authority. Project merge, deployment, production, and destructive-action rules still apply. Without that instruction, produce decisions, not deliverables.

For a planning map, prototype work stays on a throwaway branch. Record the user's decision and link the prototype. Do not promote prototype code into the real implementation without separate user authorization, even if a companion skill says to fold it in.

When this skill names the Skill tool, use the active runtime's skill-loading mechanism. If it has no Skill tool, or the named companion is not exposed through that tool, read the named installed `SKILL.md` and follow it within the user's Wayfinder invocation. Use the active runtime's supported agent tools for subagents. If delegation is unavailable, report that limit and do the research in the current session.

## Session coordination

Use one tracker-writing coordinator per repository. Before charting or working a map, resolve the shared Git directory with `git rev-parse --path-format=absolute --git-common-dir`. Acquire `<git-common-dir>/wayfinder-session.lock` with atomic `mkdir`, without `-p`. Only the successful caller may claim tickets or edit maps. If it already exists, inspect its owner and stop tracker writes while that coordinator is active. Assignment alone is not an exclusive claim.

After acquisition, write an owner record inside the lock directory: a unique session token, hostname, the long-lived coordinator process's PID and start time, and UTC acquisition time. Do not use a transient tool-shell PID. Keep this runtime state out of commits. All sessions and worktrees for this repository must use this shared lock. If a shared lock cannot be acquired, report the limit and do only read-only work. The lock does not coordinate separate clones or machines: those sessions must remain read-only until the human confirms that the old coordinator has ended and hands off tracker-writing ownership.

Keep the lock for the session, including map read-modify-write updates. Research workers may write findings in isolated worktrees, but they return results to the coordinator. Only the coordinator records answers, closes tickets, and edits the map, serially against the latest state.

On orderly exit, return the coordinator's unfinished claims to the open state and record that work stopped. Release only its own lock, after verifying the owner token. After an interruption, verify the old process identity using hostname, PID, and start time. Do not automatically delete another owner's lock. The human must confirm that all coordinators stopped and designate one recovery session. That session rechecks the owner record before removing the abandoned lock, then acquires a new lock with atomic `mkdir` before recovering unfinished claims. A changed owner record stops cleanup. A timeout alone is not evidence that a session ended. Missing or unreadable ownership data still requires this human-selected recovery. Preserve all ticket content and completed decisions.

## Refer by name

Every map and ticket is an issue, so it has a **name**: its title. In everything the human reads (narration, the map's Decisions-so-far), refer to it by that name, never by a bare id, number, or slug. A wall of `#42, #43, #44` is illegible; names read at a glance. The id and URL don't vanish; a name wraps its link, but they ride _inside_ the name, never stand in for it.

## The Map

The map is a single issue on this repo's issue tracker, labelled `wayfinder:map`, the canonical artifact. Its tickets are child issues of the map.

The map is an **index**, not a store. It lists the decisions made and points at the tickets that hold their detail; a decision lives in exactly one place, its ticket, so the map never restates it, only gists it and links.

**Where the map, its child tickets, blocking, and frontier queries physically live is tracker-specific.** Read `docs/agents/issue-tracker.md` when it exists, or the tracker doc named by the repo's agent instructions. Consult its "Wayfinding operations" section for how _this_ repo expresses them. If no tracker doc is configured, use the bundled [local-Markdown tracker](issue-tracker-local.md). Its maps live at `.scratch/<effort>/map.md`, with one file per ticket in `.scratch/<effort>/issues/`. This fallback works without editing the repo's agent instructions. If a configured doc lacks Wayfinding operations, report the missing instructions and obtain them before writing to that tracker.

### The map body

The whole map at low resolution, loaded once per session. Open tickets are **not** listed: they are open child issues, found by query.

```markdown
## Destination

<what reaching the end of this map looks like: the spec, decision, or change this effort is finding its way to. One or two lines; every session orients to it before choosing a ticket.>

## Notes

<domain; skills every session should consult; standing preferences for this effort>

## Decisions so far

<!-- the index: one line per closed ticket, enough to judge relevance, then zoom the link for the detail the ticket holds -->

- [<closed ticket title>](link): <one-line gist of the answer>

## Not yet specified

<!-- see "Fog of war": in-scope fog you can't ticket yet; graduates as the frontier advances -->

## Out of scope

<!-- see "Out of scope": work ruled beyond the destination; closed, never graduates -->
```

### Tickets

Each ticket is a **child issue** of the map; the tracker's issue id is its identity. Its body is the question, sized to one 100K token agent session:

```markdown
## Question

<the decision or investigation this ticket resolves>
```

Each ticket carries a `wayfinder:<type>` label, one of `research`, `prototype`, `grilling`, `task` (see [Ticket Types](#ticket-types)).

The coordinator **claims** a ticket by assigning it to the dev driving the map, **first**, before any work. Assignment records the claim; the shared session lock gives exclusive ownership. Re-read the ticket under that lock before claiming it. An open, unassigned ticket is unclaimed.

Blocking uses the tracker's **native** dependency relationship: essential because it renders the frontier _visually_ in the tracker's own UI, so the human sees what's takeable without opening the map. Only a tracker that lacks native blocking falls back to a body convention. A ticket is **unblocked** when every ticket blocking it is closed; the **frontier** is the open, unblocked, unclaimed children, the edge of the known.

The answer isn't part of the body; it's recorded on resolution (see [Work through the map](#work-through-the-map)). Assets created while resolving a ticket are linked from the issue, not pasted in.

## Ticket Types

Every ticket is either **HITL** (human in the loop, worked _with_ a human who speaks for themselves) or **AFK**, driven by the agent alone. A HITL ticket only resolves through that live exchange; the agent never stands in for the human's side of it (a grilling agent that answers its own questions has broken this).

- **Research** (AFK): Reading documentation, third-party APIs, or local resources like knowledge bases to surface a fact a decision waits on. Resolved by a subagent that calls the Skill tool with "research". Use when knowledge outside the current working directory is required.
- **Prototype** (HITL): Raise the fidelity of the discussion by making a cheap, rough, concrete artifact to react to (an outline, a rough take, a stub, or UI/logic code) by calling the Skill tool with "prototype". Links the prototype as an asset. Use when "how should it look" or "how should it behave" is the key question.
- **Grilling** (HITL): Conversation. The default case. Always call the Skill tool twice, for "grilling" and "domain-modeling".
- **Task** (HITL or AFK): Manual work that must happen before a _decision_ can be made: nothing to decide, prototype, or research, but the discussion is blocked until it's done. Signing up for a service so its API can be judged, provisioning access, moving data so its shape can be seen. This is the one type that _does_ rather than decides, and it earns its place by unblocking a decision, not by delivering the destination. The agent drives it alone where it can (AFK); otherwise it hands the human a precise checklist (HITL). Resolved when the work is done; the answer records what was done and any resulting facts (credentials location, new URLs, row counts) later tickets depend on.

## Fog of war

The map is _deliberately_ incomplete: don't chart what you can't yet see. Beyond the live tickets lies the **fog of war**: the dim view of decisions and investigations you can tell are coming but can't yet pin down, because they hang on questions still open. Resolving a ticket clears the fog ahead of it, graduating whatever's now specifiable into fresh tickets, one at a time, until the way to the destination is clear and no tickets remain.

The map's **Not yet specified** section is where that dim view is written down: the suspected question, the area to revisit later. It's the undiscovered frontier _toward_ the destination: everything here is in scope, just not sharp enough to ticket. Write as loosely or as fully as the view allows; it doubles as a signpost for collaborators reading where the effort is headed.

**Fog or ticket?** The test is whether you can state the question precisely now, _not_ whether you can answer it now.

- **Ticket when** the question is already sharp, even if it's blocked and you can't act on it yet.
- **Not yet specified when** you can't yet phrase it that sharply. Don't pre-slice the fog into ticket-sized pieces: it's coarser than a ticket, and one patch may graduate into several tickets, or none, once the frontier reaches it.

**Not yet specified** excludes what's already decided (Decisions so far), what's already a live ticket, and what's out of scope (the next section).

## Out of scope

Fog only ever gathers _toward_ the destination. The destination fixes the scope, so work beyond it is **out of scope**: it isn't fog, and it doesn't belong in **Not yet specified**. It gets its own **Out of scope** section on the map: work you've consciously ruled out of _this_ effort. Scope, not sharpness, lands it here.

Out-of-scope work never graduates (the frontier stops at the destination), so it returns only if the destination is redrawn, and then as a fresh effort, not a resumption.

Ruling something out of scope is a scoping act, not a step on the route. When a ticket that already exists turns out to sit past the destination (mis-scoped in while charting, or exposed by a resolution), **close it** (a closed ticket is unambiguously off the frontier) and leave one line in the **Out of scope** section: the gist plus why it's out of scope, linking the closed ticket. It stays out of **Decisions so far**, which records the route actually walked; a scope boundary isn't a step on it.

## Invocation

Two modes. Either way, **never resolve more than one ticket per session**, with the exception of research tickets.

### Chart the map

User invokes with a loose idea.

1. **Name the destination.** Call the Skill tool twice, for "grilling" and "domain-modeling", to pin down what this map is finding its way to: the spec, decision, or change. The destination fixes the scope, so it's settled first.
2. **Map the frontier.** Grill again, **breadth-first** this time: fan out across the whole space rather than deep on any one thread, surfacing the open decisions and the first steps takeable now. If there are no unresolved decisions to ticket and no fog, the way is clear and you don't need a map. Stop and ask the user how they'd like to proceed. Create a map when unresolved decisions remain, even if each question is already precise and there is no fog.
3. **Create the map** (label `wayfinder:map`): Destination and Notes filled in, Decisions-so-far empty, the fog sketched into **Not yet specified**.
4. **Create the tickets you can specify now** as child issues of the map, then wire blocking edges in a **second pass** (issues need ids before they can reference each other). Wiring sorts them into the frontier and the blocked; everything you can't yet specify stays in the fog: the **Not yet specified** section.
5. **Fire the research subagents.** For each unblocked, unclaimed `research` ticket you just created, claim it first and spin up a subagent that calls the Skill tool with "research". Give each writing worker a separate worktree on a distinct throwaway `research/<name>` branch. Nested research workers must use that isolated worktree. Never switch branches in a checkout shared by concurrent workers. If isolated worktrees are unavailable, workers return findings without writing or switching branches; the parent saves and commits them serially. Workers return their answers and asset pointers without editing the tracker. The coordinator records each research resolution and links its findings branch from the ticket, serially.
6. Stop: charting is one session's work; it hand-resolves nothing.

### Work through the map

User invokes with a map (URL or number). A ticket is **optional**: without one, you pick the next decision, not the user.

1. Load the **map**: the low-res view, not every ticket body.
2. Check all open children and **Not yet specified** before choosing a ticket. If both are empty, complete the map using the tracker instructions and hand off the Destination and Decisions-so-far index. If the frontier is empty but open tickets remain, report their blockers or claims; do not complete the map or take a blocked ticket. If only fog remains, refine it with the human into tickets before selection. If the user named a ticket, verify it is open, unblocked, and unclaimed. Otherwise take the first frontier ticket in order. **Claim it**: assign it to yourself before any work.
3. Resolve it. **Zoom as needed**: fetch the full body of any related or closed ticket on demand; call the Skill tool for whichever skills the `## Notes` block names. If in doubt, call the Skill tool twice, for "grilling" and "domain-modeling".
4. Classify the result before recording it. If the ticket is out of scope, close it with the reason and link it only from **Out of scope**. Otherwise post the answer as a **resolution comment**, **close** the issue, and **append a context pointer** to the map's Decisions-so-far.
5. Add newly-surfaced in-scope tickets (create-then-wire); graduate any fog the answer has made specifiable, clearing each graduated patch from **Not yet specified** so it lives only as its new ticket. Rule any other ticket beyond the destination out of scope before recording it in the decision index. If the decision invalidates other parts of the map, update or delete those tickets. Re-read the current map and all open children after these updates. Complete the map and hand off its Destination and decision index only when no open child and no fog remains.

Research workers may run in parallel. Ticket claims, resolutions, and map updates remain serialized through the coordinator. Complete its tracker writes before releasing the shared lock.
