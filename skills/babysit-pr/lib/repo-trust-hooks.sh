#!/usr/bin/env bash
# shellcheck shell=bash
# Hook discovery and loading for babysit-prs.sh. Sourced at top
# level, not from a function, so each hook file is sourced in global scope as
# before. A hook file inside $REPO_ROOT runs checkout code the moment it is
# sourced: the two conventional root hooks, and any `--hook` or BABYSIT_HOOK
# that resolves into the checkout. Before any such file loads, every watched PR
# is pinned: one canonical GitHub origin serving the watched repository, a
# same-repository head, and the base and default-branch OIDs. A refusal loads
# none of them, and the repo gate fails. After the init ran, every pin is
# verified again. Each later adapter call goes through `trust_guard`.

if [[ -n ${BABYSIT_HOOK-} ]]; then
	EXPLICIT_HOOKS+=("$BABYSIT_HOOK")
fi
ROOT_HOOKS_PRESENT=0
if [[ $ROOT_MATCHES_WATCHED == "1" ]] && [[ -f "$REPO_ROOT/.claude/babysit-pr.sh" || -f "$REPO_ROOT/.github/babysit-pr.sh" ]]; then
	ROOT_HOOKS_PRESENT=1
fi
for hook in ${EXPLICIT_HOOKS[@]+"${EXPLICIT_HOOKS[@]}"}; do
	[[ -f $hook ]] || {
		echo "hook not found: $hook" >&2
		exit 2
	}
	hook_in_root "$hook" && ROOT_HOOKS_PRESENT=1
done
# A refusal is final. A failed read or drift reports PENDING and is retried
# each poll interval, still before any hook loads, while the budget holds one
# more attempt; what remains unresolved then keeps every checkout hook out and
# the repo gate PENDING.
if [[ $ROOT_HOOKS_PRESENT == "1" ]]; then
	while ! trust_pin_all before; do
		[[ $ROOT_HOOK_TRUST_BUCKET == "PENDING" ]] || break
		((HARD_DEADLINE - $(date +%s) > POLL_INTERVAL)) || break
		printf '[#ALL] REPO_TRUST_PENDING elapsed=%sm - %s; retrying before any hook loads\n' \
			"$((($(date +%s) - START) / 60))" "$ROOT_HOOK_TRUST"
		ROOT_HOOK_TRUST=""
		sleep "$POLL_INTERVAL"
	done
fi
if [[ $ROOT_MATCHES_WATCHED == "0" ]]; then
	echo "$REPO_ROOT is not $REPO_SLUG (origin: $REPO_ROOT_SLUG) - skipping its hooks and every repo and package gate; generic defaults apply" >&2
elif [[ -n $ROOT_HOOK_TRUST && $ROOT_HOOK_TRUST_BUCKET == "PENDING" ]]; then
	echo "repo trust preflight could not decide on the hooks in $REPO_ROOT within the budget: $ROOT_HOOK_TRUST - the repo gate stays PENDING" >&2
elif [[ -n $ROOT_HOOK_TRUST ]]; then
	echo "repo trust preflight refused the hooks in $REPO_ROOT: $ROOT_HOOK_TRUST - the repo gate fails until a trusted checkout runs the watch" >&2
else
	add_hook_if_exists "$REPO_ROOT/.claude/babysit-pr.sh"
	add_hook_if_exists "$REPO_ROOT/.github/babysit-pr.sh"
fi
for hook in ${EXPLICIT_HOOKS[@]+"${EXPLICIT_HOOKS[@]}"}; do
	if [[ -n $ROOT_HOOK_TRUST ]] && hook_in_root "$hook"; then
		echo "repo trust preflight refused the hook $hook inside $REPO_ROOT: $ROOT_HOOK_TRUST" >&2
		continue
	fi
	HOOKS+=("$hook")
done

# Each checkout hook file is sourced only while every pin still verifies, and
# the pins are verified again right after it, so one file cannot repoint
# origin and still have the next one load. The first failure stops every
# later checkout hook and fails the repo gate.
for hook in ${HOOKS[@]+"${HOOKS[@]}"}; do
	if hook_needs_pin "$hook"; then
		if [[ -n $ROOT_HOOK_TRUST ]]; then
			echo "repo trust preflight skipped the hook $hook: $ROOT_HOOK_TRUST" >&2
			continue
		fi
		trust_pin_all after || {
			echo "repo trust preflight failed before sourcing $hook: $ROOT_HOOK_TRUST" >&2
			continue
		}
		# shellcheck source=/dev/null
		. "$hook"
		trust_pin_all after || echo "repo trust preflight failed after sourcing $hook: $ROOT_HOOK_TRUST" >&2
		continue
	fi
	# shellcheck source=/dev/null
	. "$hook"
done

if type babysit_repo_init >/dev/null 2>&1; then
	babysit_repo_init "$OWNER" "$REPO" "$REPO_ROOT"
fi
# Every hook has loaded and the init ran. A PENDING result from this verify
# does not stop the watch: root_hook_trust_gate lets the gate's own guard
# re-pin on the next evaluation. Only a refusal is final.
if [[ $ROOT_HOOKS_PRESENT == "1" && -z $ROOT_HOOK_TRUST ]]; then
	# shellcheck disable=SC2034 # read by repo-trust.sh
	ROOT_HOOKS_COMPLETE=1
	trust_pin_all after || echo "repo trust preflight failed after the hooks in $REPO_ROOT loaded: $ROOT_HOOK_TRUST" >&2
fi
