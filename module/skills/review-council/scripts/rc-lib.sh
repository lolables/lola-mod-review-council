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

# JSON output helper
json_output() {
	jq -n \
		--arg status "$1" \
		--arg message "$2" \
		--argjson extra "${3:-{}}" \
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
