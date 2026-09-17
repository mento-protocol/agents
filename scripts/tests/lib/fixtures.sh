# shellcheck shell=bash
#
# fixtures.sh - builders for the trees a case runs against: skill directories,
# the sources file, and the bare repository with its seed and company clones.
#
# Reads: CASE_DIR, SOURCE_SCRIPT, HOME.
# Writes: BARE, SEED, COMPANY, LS, and files under CASE_DIR and HOME.
#
# LS is written here and read by case.sh, so shellcheck sees no reader while
# it lints this file on its own.
# shellcheck disable=SC2034

gitc() {
	local d
	d=$1
	shift
	git -C "$d" -c user.name=t -c user.email=t@example.com "$@"
}

mkskill() {
	mkdir -p "$1/$2"
	{
		printf -- '---\n'
		printf 'name: %s\n' "$2"
		printf 'description: test skill for the link-skills harness\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$1/$2/SKILL.md"
}

write_sources() {
	mkdir -p "$HOME/.agents"
	: >"$HOME/.agents/skill-sources"
}

add_source() {
	printf '%s\n' "$1" >>"$HOME/.agents/skill-sources"
}

# A bare repository, a seed clone that pushes commits, and the clone the
# sources file points at. The script under test is committed into the repo so
# that the clone looks exactly like a coworker's checkout.
fixture_company() {
	BARE="$CASE_DIR/remote.git"
	SEED="$CASE_DIR/seed"
	COMPANY="$CASE_DIR/company"
	git init --bare --quiet "$BARE"
	git -C "$BARE" symbolic-ref HEAD refs/heads/main
	git clone --quiet "$BARE" "$SEED" 2>/dev/null
	git -C "$SEED" symbolic-ref HEAD refs/heads/main
	mkdir -p "$SEED/scripts"
	cp "$SOURCE_SCRIPT" "$SEED/scripts/link-skills.sh"
	chmod +x "$SEED/scripts/link-skills.sh"
	mkskill "$SEED/skills" alpha
	gitc "$SEED" add -A
	gitc "$SEED" commit -q -m "init"
	git -C "$SEED" push -q origin main
	git clone --quiet "$BARE" "$COMPANY"
	LS="$COMPANY/scripts/link-skills.sh"
}

push_beta() {
	mkskill "$SEED/skills" beta
	gitc "$SEED" add -A
	gitc "$SEED" commit -q -m "add beta"
	git -C "$SEED" push -q origin main
}

head_of() {
	git -C "$1" rev-parse HEAD
}
