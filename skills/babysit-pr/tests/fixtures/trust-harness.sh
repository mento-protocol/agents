#!/usr/bin/env bash
# Shared fixture for the repository-trust preflight tests. Sourced, not run:
#   babysit-pr/tests/repo-trust-preflight.test.sh
#   babysit-pr/tests/repo-trust-adapter-guard.test.sh
#   ship-pr/scripts/publish-target.test.sh
#
# The checkout is a real git repository, so remote URLs, insteadOf expansion,
# refs, and HEAD behave as they do for a user. Two commands are faked:
# - `git fetch` (after any leading `-c key=value` overrides, which are logged to
#   `$FX/git-config-overrides.log`) updates the requested remote-tracking refs to the OIDs in
#   `$FX/served/<branch>` (slashes as `__`), and logs the call to
#   `$FX/fetch.log`. `git push` is logged to `$FX/push.log` and succeeds
#   unless `$FX/push.fail` exists. Every other git subcommand runs the real git.
# - `gh` answers from JSON fixtures and applies `--jq` with the real `jq`, so
#   the preflight's own jq expressions are under test:
#     repo view SLUG     -> $FX/repo/<owner>__<name>.json (lowercase)
#     pr view N          -> $FX/pr/<N>.json; after that read, $FX/pr/<N>.next.json
#                           replaces it when present, so a second read differs
#     pr list            -> $FX/prlist.json ($FX/prlist.fail forces an error)
#     api repos/R/branches/B -> $FX/branches/<B>.json
#   Every gh call is logged to `$FX/gh.log`.
# The caller sets TMP_DIR before sourcing. Global and system git config are
# replaced so a developer's own insteadOf rules cannot change the result.

FX="$TMP_DIR/fx"
WORK="$TMP_DIR/work"
TRUST_BIN="$TMP_DIR/trust-bin"
REAL_GIT=$(command -v git)
mkdir -p "$FX/repo" "$FX/pr" "$FX/branches" "$FX/served" "$TRUST_BIN" "$WORK"

export GIT_CONFIG_GLOBAL="$TMP_DIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

cat >"$TRUST_BIN/git" <<EOF
#!/usr/bin/env bash
set -u
REAL_GIT="$REAL_GIT"
FX="$FX"
dir=""
args=("\$@")
if [[ "\${1:-}" == "-C" ]]; then
  dir=\$2
  args=("\${@:3}")
fi
overrides=()
while [[ "\${args[0]:-}" == "-c" ]]; do
  printf '%s\n' "-c \${args[1]}" >> "\$FX/git-config-overrides.log"
  overrides+=(-c "\${args[1]}")
  args=("\${args[@]:2}")
done
if [[ "\${args[0]:-}" == "push" ]]; then
  # Parse like git: before \`--\`, an argument starting with \`-\` is an option,
  # and an unknown one (a remote named -fork, say) is a usage error. The log
  # records the operands without the \`--\`.
  logged=(push)
  operands=0
  for arg in "\${args[@]:1}"; do
    if [[ "\$operands" == "0" && "\$arg" == "--" ]]; then operands=1; continue; fi
    if [[ "\$operands" == "0" && "\$arg" == -* && "\$arg" != "--set-upstream" ]]; then
      echo "error: unknown switch \$arg" >&2
      exit 129
    fi
    logged+=("\$arg")
  done
  printf '%s\n' "\${logged[*]}" >> "\$FX/push.log"
  [[ ! -f "\$FX/push.fail" ]] || exit 1
  exit 0
fi
if [[ "\${args[0]:-}" != "fetch" ]]; then
  exec "\$REAL_GIT" "\$@"
fi
printf '%s\n' "\${args[*]}" >> "\$FX/fetch.log"
[[ ! -f "\$FX/fetch.fail" ]] || exit 1
# \`$FX/real-fetch-from\` names a local bare repository: run a real fetch from
# it with the caller's overrides, so checkout config really takes effect. The
# file transport is allowed last, for this local fixture only.
if [[ -f "\$FX/real-fetch-from" ]]; then
  specs=()
  for spec in "\${args[@]}"; do
    [[ "\$spec" == +refs/heads/*:refs/remotes/* ]] && specs+=("\$spec")
  done
  exec "\$REAL_GIT" \${dir:+-C "\$dir"} "\${overrides[@]}" -c protocol.file.allow=always \
    fetch --no-tags --quiet "\$(cat "\$FX/real-fetch-from")" "\${specs[@]}"
fi
for spec in "\${args[@]}"; do
  case "\$spec" in
    +refs/heads/*:refs/remotes/*)
      src=\${spec#+refs/heads/}
      src=\${src%%:*}
      dst=\${spec#*:}
      oid=\$(cat "\$FX/served/\${src//\//__}") || exit 1
      "\$REAL_GIT" \${dir:+-C "\$dir"} update-ref "\$dst" "\$oid" || exit 1
      ;;
  esac
done
EOF
chmod +x "$TRUST_BIN/git"

cat >"$TRUST_BIN/gh" <<EOF
#!/usr/bin/env bash
set -u
FX="$FX"
EOF
cat >>"$TRUST_BIN/gh" <<'EOF'
printf '%s\n' "$*" >> "$FX/gh.log"
jq_expr="."
paginate=0
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jq) jq_expr=$2; shift 2 ;;
    --paginate) paginate=1; shift ;;
    --json|--repo|--head|--state) shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
file=""
case "${positional[0]:-} ${positional[1]:-}" in
  "repo view") slug=$(lower "${positional[2]}"); file="$FX/repo/${slug/\//__}.json" ;;
  "pr view") file="$FX/pr/${positional[2]}.json" ;;
  api\ repos/*/pulls\?*)
    # Like GitHub: filter `$FX/prlist.json` by the `head=owner:branch` query,
    # then serve pages of 30; without --paginate only the first page.
    [[ ! -f "$FX/prlist.fail" ]] || exit 1
    [[ -s "$FX/prlist.json" ]] || exit 0
    query=${positional[1]#*\?}
    head=${query##*head=}
    head=${head%%&*}
    head=$(printf '%b' "${head//%/\\x}")
    filtered=$(jq -c --arg owner "${head%%:*}" --arg ref "${head#*:}" \
      '[.[] | select((.head.repo.owner.login | ascii_downcase) == ($owner | ascii_downcase) and (.head.ref == $ref or .head.ref == "*")) | if .head.ref == "*" then .head.ref = $ref else . end]' "$FX/prlist.json") || exit 1
    pages=$(jq -c '. as $a | [range(0; ([($a | length), 1] | max); 30) | $a[.:(. + 30)]] | .[]' <<< "$filtered") || exit 1
    [[ "$paginate" == "1" ]] || pages=$(head -n 1 <<< "$pages")
    jq -r "$jq_expr" <<< "$pages"
    exit $?
    ;;
  api\ repos/*)
    # `$FX/branches.fail-once` makes the next branch read fail, once.
    if [[ -f "$FX/branches.fail-once" ]]; then
      rm -f "$FX/branches.fail-once"
      exit 1
    fi
    # Like an HTTP client: `#` starts a fragment and `?` a query, neither is
    # part of the path. Then percent-decode the one path segment.
    path=${positional[1]#repos/}
    path=${path#*/*/branches/}
    path=${path%%#*}
    path=${path%%\?*}
    path=$(printf '%b' "${path//%/\\x}")
    file="$FX/branches/${path//\//__}.json"
    ;;
esac
[[ -n "$file" && -f "$file" ]] || { echo "fake gh: no fixture for: ${positional[*]}" >&2; exit 1; }
jq -r "$jq_expr" "$file"
status=$?
if [[ "${positional[0]:-} ${positional[1]:-}" == "pr view" && -f "${file%.json}.next.json" ]]; then
  mv -f "${file%.json}.next.json" "$file"
fi
exit "$status"
EOF
chmod +x "$TRUST_BIN/gh"

# trust_repo_init: a checkout with two commits on main and origin pointing at
# acme/widgets. Prints nothing; sets C1 (main tip) and C2 (feature tip).
trust_repo_init() {
	"$REAL_GIT" -C "$WORK" init -q -b main
	"$REAL_GIT" -C "$WORK" config user.name "Trust Fixture"
	"$REAL_GIT" -C "$WORK" config user.email "trust@example.invalid"
	printf 'one\n' >"$WORK/file"
	"$REAL_GIT" -C "$WORK" add file
	"$REAL_GIT" -C "$WORK" commit -qm one
	C1=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
	"$REAL_GIT" -C "$WORK" checkout -q -b feature
	printf 'two\n' >>"$WORK/file"
	"$REAL_GIT" -C "$WORK" commit -qam two
	# shellcheck disable=SC2034 # read by the tests that source this harness
	C2=$("$REAL_GIT" -C "$WORK" rev-parse HEAD)
	"$REAL_GIT" -C "$WORK" remote add origin git@github.com:acme/widgets.git
	printf '%s\n' "$C1" >"$FX/served/main"
	trust_repo_json acme/widgets main
	trust_branch_json main "$C1" true
	printf '[]\n' >"$FX/prlist.json"
}

# trust_repo_json SLUG DEFAULT_BRANCH [PARENT_SLUG]
trust_repo_json() {
	local slug=$1 default=$2 parent=${3-} lower file parent_json=null
	lower=$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')
	file="$FX/repo/${lower/\//__}.json"
	if [[ -n $parent ]]; then
		parent_json=$(printf '{"name":"%s","owner":{"login":"%s"}}' "${parent#*/}" "${parent%%/*}")
	fi
	printf '{"nameWithOwner":"%s","parent":%s,"defaultBranchRef":{"name":"%s"}}\n' \
		"$slug" "$parent_json" "$default" >"$file"
}

# trust_branch_json BRANCH SHA PROTECTED
trust_branch_json() {
	printf '{"name":"%s","commit":{"sha":"%s"},"protected":%s}\n' "$1" "$2" "$3" >"$FX/branches/${1//\//__}.json"
}

# trust_pr_json N HEAD_OWNER HEAD_NAME HEAD_REF HEAD_OID BASE_REF CROSS [STATE] [URL]
trust_pr_json() {
	printf '{"number":%s,"state":"%s","headRefName":"%s","headRefOid":"%s","baseRefName":"%s","isCrossRepository":%s,"headRepositoryOwner":{"login":"%s"},"headRepository":{"name":"%s"},"url":"%s"}\n' \
		"$1" "${8:-OPEN}" "$4" "$5" "$6" "$7" "$2" "$3" "${9:-https://github.com/acme/widgets/pull/$1}" >"$FX/pr/$1.json"
}
