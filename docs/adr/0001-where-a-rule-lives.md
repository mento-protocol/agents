# Each rule has one home: the skill, the target repository, or the user's own instructions

A skill in `skills/` holds only behavior that serves every user in every
repository. A rule that holds for one repository lives in that repository's
agent instructions, so that every teammate working there gets it. A rule that
one user applies across repositories lives in that user's own agent
instructions, such as a global `CLAUDE.md` or `AGENTS.md`. We record this
because it is hard to reverse once teammates rely on what a skill does, and
because a reader will wonder why a skill does not do what a user's own
instructions make it do.

## Considered Options

- **A per-user settings file that the skills read.** Rejected. Each skill
  would need code to find, parse, and validate the file, and a reader of a
  skill could not see its behavior without that file. The runtime already
  loads the user's own instructions into every session, so they reach every
  skill without new code.

## Consequences

- When a skill moves here from a personal library, each rule in it is sorted
  into one of the three homes. A personal preference is removed from the skill
  and kept in the owner's own instructions.
- A user who wants different behavior writes it in their own instructions; the
  skill does not grow an option for it.
