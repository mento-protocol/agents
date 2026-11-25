# Claude Code adapter

`grilling` sets `disable-model-invocation: true`, so the Skill tool refuses it.
Read `grilling/SKILL.md` from the skills directory this skill lives in, and
follow it. That directory is the parent of the base directory shown when this
skill loads, normally `~/.claude/skills`. Use the path as shown and do not
resolve symlinks: the two skills can come from different repositories.

If you cannot find that file, stop and tell the user the path you tried. Do
not improvise the interview.

Call the Skill tool once for `domain-modeling`.
