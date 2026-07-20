#!/usr/bin/env bash
# Shared library for review-council scripts.
# Source this file; do not execute it directly.
#
# Provides:
#   - Bash 4+ and jq prerequisite checks (exits gracefully if missing)
#   - json_output()  — structured JSON output helper
#   - build_repo_flag() — constructs --repo flag for gh/glab CLI

# Guard: skip if already loaded
[[ -n "${_RC_LIB_LOADED:-}" ]] && return 0
_RC_LIB_LOADED=1

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo '{"status":"skip","message":"Bash 4+ is required. macOS ships Bash 3 — install a modern version: brew install bash"}'
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	echo '{"status":"skip","message":"jq is required but not installed. Install it: apt-get install jq | brew install jq | dnf install jq"}'
	exit 0
fi

# JSON output helper.
# Optional 3rd arg is a JSON object merged into the result; defaults to {}.
# NOTE: assign via a local first — the inline form ${3:-{}} is a brace-parsing
# trap (the expansion closes at the first '}', leaving a stray literal '}').
json_output() {
	local extra="${3:-}"
	[[ -z "$extra" ]] && extra="{}"
	jq -n \
		--arg status "$1" \
		--arg message "$2" \
		--argjson extra "$extra" \
		'$extra + {status: $status, message: $message}'
}

# Build --repo flag for gh/glab CLI from forge owner and repo variables.
# Usage: repo_flag=$(build_repo_flag "$forge_owner" "$forge_repo")
build_repo_flag() {
	local owner="$1" repo="$2"
	if [[ -n "$owner" ]] && [[ -n "$repo" ]]; then
		echo "--repo ${owner}/${repo}"
	fi
}

# Read the value of a "- Key: value" or "Key: value" line from a file.
# Returns the first match's value, trimmed. Empty string if not found.
# Usage: value=$(rc_parse_kv "$file" "Forge")
rc_parse_kv() {
	local file="$1" key="$2"
	[[ -f "$file" ]] || return 0
	grep -m1 -E "^[-[:space:]]*${key}:" "$file" 2>/dev/null |
		sed -E "s/^[-[:space:]]*${key}:[[:space:]]*//" |
		sed -E 's/[[:space:]]+$//' || true
}

# Fail loudly. With pipefail set, a failing pipeline stage can otherwise abort
# a script (under set -e) or be missed with no trace, producing non-reproducible
# behavior. rc_trap_errors installs an ERR trap that reports the script and line
# of any UNHANDLED command failure to stderr (stdout stays reserved for the
# script's JSON/markdown payload). Errors you handle with `|| ...`, `if`, or
# `&&`/`||` lists are exempt per bash ERR semantics, so only genuine surprises
# print. Call rc_trap_errors once, immediately after sourcing this library.
rc_on_err() {
	local code="$1" line="$2" src="${3##*/}"
	echo "rc-error: ${src}:${line}: command failed (exit ${code}) under 'set -o pipefail'" >&2
}
rc_trap_errors() {
	set -o errtrace
	trap 'rc_on_err "$?" "$LINENO" "${BASH_SOURCE[0]}"' ERR
}
