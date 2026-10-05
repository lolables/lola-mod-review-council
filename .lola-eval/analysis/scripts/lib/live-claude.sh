#!/usr/bin/env bash
# Shared helpers for scripts that make live, paid `claude` invocations under
# an isolated CLAUDE_CONFIG_DIR: ctx-measure-tax.sh and ctx-hook-probe.sh.
# Source this file; do not execute it directly.
#
# Provides:
#   - seed_auth()          — copy host credentials into a clean config dir
#   - check_claude_result() — abort loudly on a failed `claude` invocation

# Guard: skip if already loaded
[[ -n "${_LIVE_CLAUDE_LOADED:-}" ]] && return 0
_LIVE_CLAUDE_LOADED=1

# Subscription auth lives in $CLAUDE_CONFIG_DIR/.credentials.json. A freshly
# created empty config dir has none, so `claude` reports "Not logged in"
# instead of running. lola_eval's profile_setup.js (_preserveClaudeAuth) hits
# the same wall and fixes it the same way: copy only the credentials file
# into the clean room, leaving settings and plugins isolated. No-op (and no
# error) if the host has no credentials file — e.g. API-key auth via env var,
# which needs no such copy.
seed_auth() { # config_dir
	local config_dir="$1"
	local host_config="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
	local host_credentials="$host_config/.credentials.json"
	mkdir -p "$config_dir"
	if [[ -f $host_credentials ]]; then
		cp "$host_credentials" "$config_dir/.credentials.json"
	fi
}

# Aborts the calling script if a `claude` invocation exited non-zero or wrote
# anything to stderr. Both are hard failures: a `claude` call that fails
# part-way through (auth, network, a missing model) must abort the whole
# script loudly, never fall through to whatever the caller does with a
# "successful" transcript and report a number or verdict that looks
# plausible but measures nothing.
#
# $context is folded into both messages so the failure says what ran, not
# just that something aborted — e.g. "config dir $config_dir" for a script
# that runs this per-arm per-sample, or a one-line reason for a script that
# runs it once. Meant to be sourced, not subshelled: `exit 1` here ends the
# caller's whole script, which is the point — nothing after a failed
# invocation should run.
check_claude_result() { # status stderr_file context
	local status="$1" stderr_file="$2" context="$3"
	if [[ $status -ne 0 ]]; then
		echo "ERROR: claude exited $status ($context)" >&2
		cat "$stderr_file" >&2
		exit 1
	fi
	if [[ -s $stderr_file ]]; then
		echo "ERROR: claude wrote to stderr ($context), treating as failure:" >&2
		cat "$stderr_file" >&2
		exit 1
	fi
}
