# shellcheck shell=bash
#
# fixtures.sh - builders for the trees a case runs against: skill directories,
# the sources file, and the bare repository with its seed and company clones.
#
# Reads: CASE_DIR and SOURCE_SCRIPT (fixtures_company), HOME
# (fixtures_write_sources, fixtures_add_source), SEED (fixtures_push_beta).
# Writes: BARE, SEED, COMPANY, LS, and files under CASE_DIR and HOME.
#
# CASE_DIR and HOME belong to case.sh and stay globals rather than arguments:
# every one of the hundreds of fixture calls means the current case's HOME and
# case directory, so passing them would touch every call site, not one line.
# SEED is this module's own: fixtures_company sets it for fixtures_push_beta.

fixtures_git() {
	local d
	d=$1
	shift
	git -C "$d" -c user.name=t -c user.email=t@example.com "$@"
}

fixtures_skill() {
	mkdir -p "$1/$2"
	{
		printf -- '---\n'
		printf 'name: %s\n' "$2"
		printf 'description: test skill for the link-skills harness\n'
		printf -- '---\n\n'
		printf 'Body.\n'
	} >"$1/$2/SKILL.md"
}

fixtures_write_sources() {
	mkdir -p "$HOME/.agents"
	: >"$HOME/.agents/skill-sources"
}

fixtures_add_source() {
	printf '%s\n' "$1" >>"$HOME/.agents/skill-sources"
}

# A bare repository, a seed clone that pushes commits, and the clone the
# sources file points at. The script under test is committed into the repo so
# that the clone looks exactly like a coworker's checkout.
fixtures_company() {
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
	fixtures_skill "$SEED/skills" alpha
	fixtures_git "$SEED" add -A
	fixtures_git "$SEED" commit -q -m "init"
	git -C "$SEED" push -q origin main
	git clone --quiet "$BARE" "$COMPANY"
	# shellcheck disable=SC2034 # read by case.sh
	LS="$COMPANY/scripts/link-skills.sh"
}

fixtures_push_beta() {
	fixtures_skill "$SEED/skills" beta
	fixtures_git "$SEED" add -A
	fixtures_git "$SEED" commit -q -m "add beta"
	git -C "$SEED" push -q origin main
}

fixtures_head_of() {
	git -C "$1" rev-parse HEAD
}
