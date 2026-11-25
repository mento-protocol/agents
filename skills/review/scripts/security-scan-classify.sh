#!/usr/bin/env bash
# Classify a commit range for security review and selected scans (review §8).
# It reads only Git history, so it needs no scanner, sign-in or network.
# Classification is inventory, not a scan requirement.
# Usage: security-scan-classify.sh --base REF [--head REF] [--repo PATH]
#
# Prints one JSON object:
#   classification  "code", "docs-only" or "empty" (filename-based)
#   mergeBase, head the compared commits
#   scanRelevant    paths outside the documentation-only filename class
#   pointerOnly     submodule and Git LFS pointer changes; no scanner sees
#                   their content, so inspect it directly
#   docsOnly        documentation-named paths; check rendered/agent input
# Exit 0 on success, 2 on a usage or input error.

set -euo pipefail

die() {
	printf 'security-scan-classify: %s\n' "$1" >&2
	exit 2
}

REPO=. BASE_REF="" HEAD_REF=HEAD
while (($#)); do
	case "$1" in
	--repo | --base | --head) [[ -n ${2-} ]] || die "$1 needs a value" ;;
	esac
	case "$1" in
	--repo) REPO=$2 && shift 2 ;;
	--base) BASE_REF=$2 && shift 2 ;;
	--head) HEAD_REF=$2 && shift 2 ;;
	-h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' && exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done
[[ -n $BASE_REF ]] || die "--base is required"
command -v jq >/dev/null || die "jq is required"

# Replace refs and grafts can make Git show other content for the same SHA,
# so the classifier reads the objects themselves.
git_ro() {
	# No lazy fetch in a partial clone either: a missing object is an error.
	GIT_NO_LAZY_FETCH=1 GIT_GRAFT_FILE=/dev/null git --no-replace-objects -C "$REPO" -c core.fsmonitor=false \
		-c advice.graftFileDeprecated=false "$@"
}

BASE=$(git_ro rev-parse --verify --quiet "$BASE_REF^{commit}") ||
	die "'$BASE_REF' does not resolve to a commit"
HEAD=$(git_ro rev-parse --verify --quiet "$HEAD_REF^{commit}") ||
	die "'$HEAD_REF' does not resolve to a commit"
MERGE_BASE=$(git_ro merge-base "$BASE" "$HEAD") ||
	die "$BASE_REF and $HEAD_REF have no merge base"

# A path whose change cannot alter what any program does. Everything else,
# including agent instructions in code-adjacent files, counts as scan-relevant.
docs_path() {
	local name path
	path=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	name=$(basename -- "$path")
	# Agent instructions and tool configuration drive behavior even as Markdown,
	# including variants such as CLAUDE.local.md and AGENTS.override.md.
	# Any dotfile, and anything in a dot-directory (.github, .claude, .devin,
	# .windsurf and the next tool's), is configuration: one rule, not a list.
	# SECURITY.md is guidance Codex Security reads.
	case "$name" in
	.* | agents.* | claude.* | gemini.* | skill.md | security.md | copilot-instructions.md) return 1 ;;
	esac
	case "/$path" in
	*/.*/*) return 1 ;;
	*/commands/* | */hooks/* | */prompts/* | */agents/*) return 1 ;;
	*/references/* | */templates/*) return 1 ;;
	esac
	case "$name" in
	*.md | *.markdown | *.rst | *.adoc) return 0 ;;
	*.png | *.jpg | *.jpeg | *.gif | *.webp | *.ico | *.pdf) return 0 ;;
	license | copying | notice | authors | changelog) return 0 ;;
	license.txt | copying.txt | notice.txt | authors.txt | changelog.txt) return 0 ;;
	esac
	return 1
}

# lfs_pointer OID: the blob is a Git LFS pointer. Err toward pointer-only: a
# false pointer costs only a direct inspection, since the path stays
# scan-relevant either way. Git LFS caps pointers at 1024 bytes.
lfs_pointer() {
	local size
	[[ $1 =~ ^0+$ ]] && return 1
	# An unreadable blob (a partial clone, say) is an input error, not "no pointer".
	# Read the whole payload: the size header stays readable in a corrupt object.
	# shellcheck disable=SC2015 # both failures return the same input error
	git_ro cat-file blob "$1" >/dev/null 2>&1 &&
		size=$(git_ro cat-file -s "$1" 2>/dev/null) ||
		die "cannot read blob $1; classify the range by hand"
	((size <= 1024)) || return 1
	# Git LFS also reads the pre-release "hawser" version line.
	git_ro cat-file blob "$1" 2>/dev/null | head -n 1 | tr -d '\r' |
		grep -Eqx 'version https://(git-lfs\.github\.com|hawser\.github\.com)/spec/v1'
}

# Print one "KIND<TAB>PATH" line per changed path. A range Git cannot read is
# an error, never an empty classification.
classify_lines() {
	local meta path old new oldoid newoid pointer
	LIST=$(mktemp "${TMPDIR:-/tmp}/security-scan-classify.XXXXXX")
	trap 'rm -f -- "$LIST"' EXIT
	git_ro diff --no-ext-diff --no-textconv --raw --no-renames --ignore-submodules=none -z \
		"$MERGE_BASE" "$HEAD" -- >"$LIST" || die "could not read the changes in the range"
	# Each entry is ":OLDMODE NEWMODE OLDOID NEWOID STATUS" and then the path.
	while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
		[[ $path != *$'\n'* && $path != *$'\t'* ]] ||
			die "a changed path contains a newline or tab; classify the range by hand"
		# JSON cannot carry other bytes, and jq would replace them silently.
		printf '%s' "$path" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 ||
			die "a changed path is not valid UTF-8; classify the range by hand"
		read -r old new oldoid newoid _ <<<"${meta#:}"
		# Read every blob side, so a missing one is an error even beside a pointer
		# or a gitlink. A gitlink side names a commit, not a blob.
		pointer=false
		if [[ $old == 160000 ]]; then pointer=true; elif lfs_pointer "$oldoid"; then pointer=true; fi
		if [[ $new == 160000 ]]; then pointer=true; elif lfs_pointer "$newoid"; then pointer=true; fi
		# An executable, a symlink or a submodule is code whatever its name.
		if "$pointer"; then
			printf 'pointer\t%s\n' "$path"
		elif [[ $old =~ ^(100644|000000)$ && $new =~ ^(100644|000000)$ ]] &&
			docs_path "$path"; then
			printf 'docs\t%s\n' "$path"
		else
			printf 'scan\t%s\n' "$path"
		fi
	done <"$LIST"
}

lines=$(classify_lines)
jq -R -s --arg base "$MERGE_BASE" --arg head "$HEAD" '
  [split("\n")[] | select(length > 0) | split("\t") | {kind: .[0], path: (.[1:] | join("\t"))}]
  | {mergeBase: $base, head: $head,
     scanRelevant: [.[] | select(.kind == "scan" or .kind == "pointer") | .path],
     pointerOnly: [.[] | select(.kind == "pointer") | .path],
     docsOnly: [.[] | select(.kind == "docs") | .path]}
  | {classification: (if (.scanRelevant | length) > 0 then "code"
      elif (.docsOnly | length) > 0 then "docs-only" else "empty" end)} + .' <<<"$lines"
