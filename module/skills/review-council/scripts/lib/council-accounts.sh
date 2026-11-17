# council-accounts.sh — which accounts' verdicts are the council's own.
#
# Sourced by prepare-config.sh, which reads the files below from the
# configuration source, and by the batch driver (scripts/lib/common.sh), which
# reads them from the default branch through the forge API. Both then apply
# the same rule, so a verdict counts as the council's in a review exactly when
# it does in a batch run. Self-contained: the batch driver sources nothing
# else from the module's scripts.
#
# The council is the account a run posts as, plus:
#
#   CODEOWNERS            the first of the forge's own locations that exists.
#                         Its @user owners are maintainers, who may run the
#                         council under their own token. @org/team entries and
#                         emails name no single login without further calls,
#                         so they are skipped and the skip recorded.
#   Council accounts:     further logins in the Review Council Configuration
#                         block, comma- or space-separated, for CI or bot
#                         accounts that post verdicts (e.g. `ci-bot[bot]`).
#
# A login is kept lowercase. Anything not shaped like one is recorded as
# skipped, never guessed at. Results, after rc_council_reset and the calls
# that follow it:
#
#   council_accounts          logins, in the order first named
#   council_accounts_skipped  "<entry> (team|email|not a login)", one line each
#   council_codeowners        the CODEOWNERS path read, or "none"
#
# shellcheck shell=bash
# shellcheck disable=SC2034 # the three results are read by the sourcing script.

rc_council_reset() {
	council_accounts=()
	council_accounts_skipped=()
	council_codeowners="none"
	declare -gA council_seen=()
}

# One line, control characters flattened: an entry is the configuration's
# author's text and is recorded in a one-line tracking value.
_rc_council_flat() { # text
	printf '%s' "$1" | tr '\000-\037\177' ' '
}

rc_council_add() { # entry
	local entry="$1" login="${1#@}"
	login="${login,,}"
	if [[ "$entry" == *@* && "$entry" != @* ]]; then
		council_accounts_skipped+=("$(_rc_council_flat "$entry") (email)")
	elif [[ "$login" == */* ]]; then
		council_accounts_skipped+=("$(_rc_council_flat "$entry") (team)")
	elif [[ ! "$login" =~ ^[a-z0-9][a-z0-9._-]{0,99}(\[bot\])?$ ]]; then
		council_accounts_skipped+=("$(_rc_council_flat "$entry") (not a login)")
	elif [[ -z "${council_seen[$login]:-}" ]]; then
		council_seen["$login"]=1
		council_accounts+=("$login")
	fi
}

# The forge's CODEOWNERS locations, in the order it looks, one per line.
rc_council_codeowners_paths() { # forge
	case "$1" in
	gitlab) printf '%s\n' CODEOWNERS docs/CODEOWNERS .gitlab/CODEOWNERS ;;
	*) printf '%s\n' .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS ;;
	esac
}

# The @user owners of a CODEOWNERS file's <text>, read from <path>.
rc_council_from_codeowners() { # path text
	local line owner fields=()
	council_codeowners="$1"
	while IFS= read -r line; do
		line="${line%$'\r'}"
		line="${line%%#*}"
		# GitLab section headers ([Section], ^[Optional]) name no owner, but
		# may list default owners after the bracket: those are kept.
		[[ "$line" =~ ^[[:space:]]*\^?\[[^]]*\](\[[0-9]+\])?(.*)$ ]] && line="x ${BASH_REMATCH[2]}"
		read -r -a fields <<<"$line" || true
		for owner in "${fields[@]:1}"; do
			[[ "$owner" == *@* ]] && rc_council_add "$owner"
		done
	done <<<"$2"
}

# The logins a `Council accounts:` value names, comma- or space-separated.
rc_council_from_setting() { # value
	local owner fields=()
	read -r -a fields <<<"$(_rc_council_flat "${1//,/ }")" || true
	for owner in ${fields[@]+"${fields[@]}"}; do
		rc_council_add "$owner"
	done
}

# The `Council accounts:` value in an AGENTS.md or CLAUDE.md <text>: the first
# such line inside its "## Review Council Configuration" section, trimmed, the
# way prepare-config.sh reads every key. Fails when the key is absent, so a
# caller can stop at the first file that sets it, as prepare-config.sh does.
rc_council_setting_in() { # text
	local block line
	block=$(printf '%s\n' "$1" |
		sed -n '/^## Review Council Configuration$/,/^## /{/^## Review Council Configuration$/d;/^## /d;p;}')
	line=$(grep -m1 -E '^[-[:space:]]*Council accounts:' <<<"$block") || return 1
	sed -E 's/^[-[:space:]]*Council accounts:[[:space:]]*//; s/[[:space:]]+$//' <<<"$line"
}
