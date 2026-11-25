#!/usr/bin/env bash
# Tests that codex-validate.sh runs codex with the newest Sol model from the
# Codex catalog and never starts codex when that lookup fails. A stub codex on
# PATH records its arguments; CODEX_HOME points at a synthetic catalog.

set -euo pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-validate.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

fail() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

mkdir -p "$ROOT/bin" "$ROOT/repo/src" "$ROOT/codex-home"
cat >"$ROOT/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$STUB_ARGS"
cat >/dev/null
echo "VERDICT: UNCERTAIN"
STUB
chmod +x "$ROOT/bin/codex"
printf 'export const x = 1;\n' >"$ROOT/repo/src/a.ts"
printf '{"severity":"WARNING","location":"src/a.ts:1","description":"d","attack_class":"c","hunter_id":"h1"}\n' \
	>"$ROOT/finding.json"

# write_catalog <slug:visibility>... writes a synthetic models_cache.json.
write_catalog() {
	python3 - "$ROOT/codex-home/models_cache.json" "$@" <<'PY'
import json, sys
models = [dict(zip(("slug", "visibility"), item.split(":"))) for item in sys.argv[2:]]
open(sys.argv[1], "w").write(json.dumps({"etag": "synthetic", "models": models}))
PY
}

# validate runs the script with the stub first on PATH; sets rc.
validate() {
	rm -f -- "$ROOT/args"
	rc=0
	PATH="$ROOT/bin:$PATH" CODEX_HOME="$ROOT/codex-home" STUB_ARGS="$ROOT/args" \
		bash "$SRC/codex-validate.sh" "$ROOT/finding.json" "$ROOT/repo" \
		>"$ROOT/out" 2>"$ROOT/err" || rc=$?
}

write_catalog gpt-5.6-sol:list gpt-6.1-sol:list gpt-6-sol:list gpt-7-astra:list gpt-9-sol:hide
validate
[ "$rc" -eq 0 ] || fail "a catalog with Sol models must run codex (exit $rc): $(cat "$ROOT/err")"
model=$(awk 'previous == "-m" { print } { previous = $0 }' "$ROOT/args")
[ "$model" = gpt-6.1-sol ] || fail "codex must receive -m gpt-6.1-sol, got '$model'"
grep -q 'model gpt-6.1-sol' "$ROOT/err" || fail "the run line must name the model"
printf 'ok - codex receives the newest visible Sol model\n'

write_catalog gpt-7-astra:list gpt-6.1-terra:list gpt-9-sol:hide
validate
[ "$rc" -eq 70 ] || fail "a catalog without a visible Sol model must exit 70, got $rc"
[ ! -e "$ROOT/args" ] || fail "codex must not start when the lookup fails"
grep -q 'no Codex Sol model resolved' "$ROOT/err" || fail "the error must name the lookup: $(cat "$ROOT/err")"
printf 'ok - no visible Sol model: exit %s and codex never starts\n' "$rc"

rm -f -- "$ROOT/codex-home/models_cache.json"
validate
[ "$rc" -ne 0 ] || fail "a missing catalog must fail"
[ ! -e "$ROOT/args" ] || fail "codex must not start without a catalog"
printf 'ok - missing catalog: exit %s and codex never starts\n' "$rc"
