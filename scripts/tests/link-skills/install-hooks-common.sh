# shellcheck shell=bash
#
# install-hooks-common.sh - the settings-file builders shared by more than one
# install-hooks topic file. It holds no case of its own, so it has no
# cases_<topic> function, and the runner sources it before the topic files that
# call it.
#
# Public:
# - write_session_hook_settings, used by install-hooks-normalize.sh and
#   install-hooks-stale.sh.
# - write_installed_hook_settings, used by install-hooks-duplicates.sh,
#   install-hooks-options.sh and install-hooks-stale.sh.
#
# Both take the settings path as $1 and the stored hook command as $2, and
# write that file. They read no global.

# A settings file whose only SessionStart entry runs the command given.
write_session_hook_settings() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 20' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}

# An entry carrying the type and the timeout this script installs, so that the
# command alone decides what the merge makes of it.
write_installed_hook_settings() {
	printf '%s\n' \
		'{' \
		'  "hooks": {' \
		'    "SessionStart": [' \
		'      {' \
		'        "hooks": [' \
		'          {' \
		'            "type": "command",' \
		"            \"command\": \"$2\"," \
		'            "timeout": 60' \
		'          }' \
		'        ]' \
		'      }' \
		'    ]' \
		'  }' \
		'}' >"$1"
}
