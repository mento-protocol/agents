#!/usr/bin/env bash
# Tests security-scan-classify.sh on a fixture repository.

set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/security-scan-classify.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

REPO="$ROOT/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Classify Test"
git -C "$REPO" config user.email classify-test@example.invalid
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -qm "$1" && git -C "$REPO" rev-parse HEAD; }

printf '# Fixture\n' >"$REPO/README.md"
BASE=$(commit init)
printf 'More docs.\n' >>"$REPO/README.md"
mkdir -p "$REPO/docs" && printf 'x' >"$REPO/docs/logo.png"
DOCS=$(commit docs)
printf 'export const x = 1;\n' >"$REPO/change.js"
CODE=$(commit code)
chmod +x "$REPO/README.md"
EXEC=$(commit "make the readme executable")
# An uninitialised submodule: a gitlink in the index over an empty directory.
git -C "$REPO" update-index --add --cacheinfo "160000,$BASE,vendor/sub"
mkdir -p "$REPO/vendor/sub"
GITLINK=$(commit "add a submodule pointer")
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 10\n' 0 >"$REPO/auth.js"
LFS=$(commit "add an LFS pointer")
rm -- "$REPO/auth.js"
LFSDEL=$(commit "delete the LFS file")
printf 'version https://git-lfs.github.com/spec/v1\nrun();\n' >"$REPO/spoof.js"
SPOOF=$(commit "a file that only looks like a pointer")

classify() { bash "$SRC/security-scan-classify.sh" --repo "$REPO" "$@" >"$ROOT/out.json"; }
expect() {
	jq -e "$2" "$ROOT/out.json" >/dev/null || fail "$1: $(cat "$ROOT/out.json")"
	printf 'ok - %s\n' "$1"
}

classify --base "$BASE" --head "$DOCS"
expect "README and image changes are docs-only" \
	'.classification == "docs-only" and .docsOnly == ["README.md", "docs/logo.png"]'
classify --base "$BASE" --head "$BASE"
expect "an empty range is empty" '.classification == "empty"'
classify --base "$DOCS" --head "$CODE"
expect "a code file makes the range code" \
	'.classification == "code" and .scanRelevant == ["change.js"]'
classify --base "$CODE" --head "$EXEC"
expect "an executable Markdown file is code" '.scanRelevant == ["README.md"]'
classify --base "$EXEC" --head "$GITLINK"
expect "a submodule pointer is pointer-only" \
	'.classification == "code" and .pointerOnly == ["vendor/sub"]'
git -C "$REPO" config diff.ignoreSubmodules all
classify --base "$EXEC" --head "$GITLINK"
git -C "$REPO" config --unset diff.ignoreSubmodules
expect "diff.ignoreSubmodules cannot hide a submodule pointer" \
	'.classification == "code" and .pointerOnly == ["vendor/sub"]'
classify --base "$GITLINK" --head "$LFS"
expect "a Git LFS pointer is pointer-only" '.pointerOnly == ["auth.js"]'
classify --base "$LFS" --head "$LFSDEL"
expect "a deleted Git LFS file is pointer-only too" '.pointerOnly == ["auth.js"]'
classify --base "$LFSDEL" --head "$SPOOF"
expect "a file that starts like a pointer stays scan-relevant" \
	'.pointerOnly == ["spoof.js"] and .scanRelevant == ["spoof.js"]'
classify --base "$CODE"
jq -e --arg h "$SPOOF" --arg b "$CODE" '.head == $h and .mergeBase == $b' "$ROOT/out.json" \
	>/dev/null || fail "the head must default to HEAD"
printf 'ok - the head defaults to HEAD\n'

printf 'version https://hawser.github.com/spec/v1\noid sha256:%064d\nsize 10\n' 0 >"$REPO/notes.md"
LEGACY=$(commit "a legacy LFS pointer with a docs name")
classify --base "$SPOOF" --head "$LEGACY"
expect "a legacy Git LFS pointer is pointer-only, even with a docs name" \
	'.classification == "code" and .pointerOnly == ["notes.md"]'

git -C "$REPO" replace "$CODE" "$DOCS"
classify --base "$DOCS" --head "$CODE"
expect "a replace ref does not change what is classified" \
	'.classification == "code" and .scanRelevant == ["change.js"]'
git -C "$REPO" replace -d "$CODE" >/dev/null

# A range whose tree object is missing must fail, not classify as empty.
BROKEN="$ROOT/broken"
git init -q -b main "$BROKEN"
printf 'a\n' >"$BROKEN/a.js"
git -C "$BROKEN" add a.js && git -C "$BROKEN" -c user.name=t -c user.email=t@example.invalid commit -qm one
printf 'b\n' >>"$BROKEN/a.js"
git -C "$BROKEN" -c user.name=t -c user.email=t@example.invalid commit -qam two
tree=$(git -C "$BROKEN" rev-parse 'HEAD^{tree}')
rm -f -- "$BROKEN/.git/objects/${tree:0:2}/${tree:2}"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$BROKEN" --base HEAD~1 >/dev/null 2>&1 || status=$?
((status == 2)) || fail "an unreadable range must exit 2 (got $status)"
printf 'ok - an unreadable range exits 2 instead of classifying as empty\n'

# A changed blob that is missing, as in a partial clone, must fail too.
MISSING="$ROOT/missing"
git init -q -b main "$MISSING"
printf 'a\n' >"$MISSING/a.md"
git -C "$MISSING" add a.md && git -C "$MISSING" -c user.name=t -c user.email=t@example.invalid commit -qm one
printf 'b\n' >>"$MISSING/a.md"
git -C "$MISSING" -c user.name=t -c user.email=t@example.invalid commit -qam two
blob=$(git -C "$MISSING" rev-parse 'HEAD:a.md')
rm -f -- "$MISSING/.git/objects/${blob:0:2}/${blob:2}"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$MISSING" --base HEAD~1 >/dev/null 2>&1 || status=$?
((status == 2)) || fail "a missing changed blob must exit 2 (got $status)"
printf 'ok - a missing changed blob exits 2 instead of classifying\n'

# A readable LFS pointer on the old side must not hide a missing new blob.
HALF="$ROOT/half-pointer"
git init -q -b main "$HALF"
printf 'version https://git-lfs.github.com/spec/v1\noid sha256:%064d\nsize 1\n' 0 >"$HALF/b.js"
git -C "$HALF" add b.js && git -C "$HALF" -c user.name=t -c user.email=t@example.invalid commit -qm one
printf 'run();\n' >"$HALF/b.js"
git -C "$HALF" -c user.name=t -c user.email=t@example.invalid commit -qam two
blob=$(git -C "$HALF" rev-parse 'HEAD:b.js')
rm -f -- "$HALF/.git/objects/${blob:0:2}/${blob:2}"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$HALF" --base HEAD~1 >/dev/null 2>&1 || status=$?
((status == 2)) || fail "a missing blob beside a pointer must exit 2 (got $status)"
printf 'ok - a missing blob beside an LFS pointer exits 2\n'

# A gitlink replaced by a file must still read that file's blob.
SWAP="$ROOT/gitlink-to-file"
git init -q -b main "$SWAP"
git -C "$SWAP" update-index --add --cacheinfo "160000,$BASE,lib"
git -C "$SWAP" -c user.name=t -c user.email=t@example.invalid commit -qm one
git -C "$SWAP" rm -q --cached lib
printf 'run();\n' >"$SWAP/lib"
git -C "$SWAP" add lib && git -C "$SWAP" -c user.name=t -c user.email=t@example.invalid commit -qm two
blob=$(git -C "$SWAP" rev-parse 'HEAD:lib')
rm -f -- "$SWAP/.git/objects/${blob:0:2}/${blob:2}"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$SWAP" --base HEAD~1 >/dev/null 2>&1 || status=$?
((status == 2)) || fail "a missing blob beside a gitlink must exit 2 (got $status)"
printf 'ok - a missing blob beside a gitlink exits 2\n'

# A truncated object keeps a readable size header but has no readable payload.
CORRUPT="$ROOT/corrupt"
git init -q -b main "$CORRUPT"
printf '# Notes\n' >"$CORRUPT/notes.md"
git -C "$CORRUPT" add notes.md && git -C "$CORRUPT" -c user.name=t -c user.email=t@example.invalid commit -qm one
head -c 4000 /dev/urandom | base64 >>"$CORRUPT/notes.md"
git -C "$CORRUPT" -c user.name=t -c user.email=t@example.invalid commit -qam two
blob=$(git -C "$CORRUPT" rev-parse 'HEAD:notes.md')
object="$CORRUPT/.git/objects/${blob:0:2}/${blob:2}"
chmod u+w "$object" && head -c 200 "$object" >"$ROOT/truncated" && mv -f "$ROOT/truncated" "$object"
git -C "$CORRUPT" cat-file -s "$blob" >/dev/null 2>&1 || fail "the fixture needs a readable size"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$CORRUPT" --base HEAD~1 >/dev/null 2>&1 || status=$?
((status == 2)) || fail "a blob with an unreadable payload must exit 2 (got $status)"
printf 'ok - a blob with an unreadable payload exits 2\n'

# A path JSON cannot carry exactly (not UTF-8) must fail, not be rewritten.
git -C "$REPO" checkout -q "$SPOOF"
blob=$(printf 'x\n' | git -C "$REPO" hash-object -w --stdin)
git -C "$REPO" update-index --add --cacheinfo "100644,$blob,bad$(printf '\377').md"
git -C "$REPO" commit -qm "a path that is not UTF-8"
status=0
bash "$SRC/security-scan-classify.sh" --repo "$REPO" --base "$SPOOF" >/dev/null 2>&1 || status=$?
((status == 2)) || fail "a path that is not UTF-8 must exit 2 (got $status)"
printf 'ok - a path that is not UTF-8 exits 2\n'
git -C "$REPO" checkout -q "$SPOOF"

status=0
bash "$SRC/security-scan-classify.sh" --repo "$REPO" --base no-such-ref 2>/dev/null || status=$?
((status == 2)) || fail "an unknown base must exit 2 (got $status)"
printf 'ok - an unknown base exits 2\n'
for flag in --repo --base --head; do
	status=0
	bash "$SRC/security-scan-classify.sh" --base "$BASE" "$flag" 2>/dev/null || status=$?
	((status == 2)) || fail "$flag without a value must exit 2 (got $status)"
done
printf 'ok - an option without a value exits 2\n'

# The rules for single paths; the fixture covers modes and pointers.
# New files under new/, so no earlier mode (the executable README) carries over.
for path in new/README.md new/docs/guide.md new/LICENSE new/LICENSE.txt new/CHANGELOG.md \
	new/img/logo.png new/notes.RST; do
	git -C "$REPO" checkout -q "$SPOOF"
	mkdir -p "$REPO/$(dirname -- "$path")" && printf 'x\n' >"$REPO/$path"
	head=$(commit "docs $path")
	classify --base "$SPOOF" --head "$head"
	jq -e '.classification == "docs-only"' "$ROOT/out.json" >/dev/null || fail "$path must be docs"
done
printf 'ok - common docs paths are docs-only\n'
for path in requirements.txt CMakeLists.txt license.js page.mdx AGENTS.md CLAUDE.md \
	CLAUDE.local.md AGENTS.override.md docs/GEMINI.md .devin/workflows/deploy.md \
	.windsurf/rules/security.md docs/.notes.md SECURITY.md \
	review/SKILL.md .github/pull_request_template.md .claude/commands/ship.md hooks/pre.md \
	skills/x/references/guide.md; do
	git -C "$REPO" checkout -q "$SPOOF"
	mkdir -p "$REPO/$(dirname -- "$path")" && printf 'y\n' >"$REPO/$path"
	head=$(commit "code $path")
	classify --base "$SPOOF" --head "$head"
	jq -e '.classification == "code"' "$ROOT/out.json" >/dev/null || fail "$path must count as code"
done
printf 'ok - agent instructions, tool config and other files count as code\n'
