#!/usr/bin/env bash
# Shared helpers for scripts that make live, paid `claude` invocations under
# an isolated CLAUDE_CONFIG_DIR: ctx-measure-tax.sh, ctx-hook-probe.sh,
# ctx-adoption-probe.sh and cg-adoption-probe.sh.
# Source this file; do not execute it directly.
#
# Provides:
#   - seed_auth()          — copy host credentials into a clean config dir
#   - check_claude_result() — abort loudly on a failed `claude` invocation
#   - install_review_council() — lola user-scope install into an isolated home
#   - check_named_agents()  — abort unless init registered every module agent

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

# Installs the review-council module into $home_dir/.claude the way users
# install it (`lola install -s user`), so $home_dir/.claude can be passed to
# `claude` as CLAUDE_CONFIG_DIR. A raw copy of module/agents is not
# equivalent: the module's agent files carry only `description:`, Claude
# Code registers an agent only when its frontmatter has `name:`, and lola is
# what adds that line (#109). HOME scopes lola's own registry to $home_dir
# too; CLAUDE_CONFIG_DIR is unset so lola cannot write to the caller's.
install_review_council() { # home_dir module_dir
	local home_dir="$1" module_dir="$2"
	if ! command -v lola >/dev/null; then
		echo "ERROR: lola not on PATH — needed to install review-council the way users do" >&2
		exit 1
	fi
	mkdir -p "$home_dir"
	env -u CLAUDE_CONFIG_DIR HOME="$home_dir" lola mod add "$module_dir" -n review-council >/dev/null
	env -u CLAUDE_CONFIG_DIR HOME="$home_dir" lola install review-council -a claude-code -s user -f >/dev/null
}

# Aborts the calling script unless the transcript's system/init event lists
# every agent in $module_dir/agents as a registered type. Without them the
# orchestrator dispatches generic agents with inlined personas — a run that
# completes and looks normal but measures the fallback path, not the one a
# real install takes. Expected names are discovered from the module so a new
# reviewer is covered without editing this check.
check_named_agents() { # transcript_file module_dir context
	local transcript_file="$1" module_dir="$2" context="$3"
	local agent_files=("$module_dir"/agents/*.md) expected missing
	expected="$(jq -nc '$ARGS.positional | map(sub(".*/"; "") | sub("\\.md$"; ""))' --args "${agent_files[@]}")"
	missing="$(jq -rs --argjson expected "$expected" '
		(map(select(.type == "system" and .subtype == "init")) | first | .agents // []) as $registered
		| $expected - $registered | join(" ")
	' "$transcript_file")"
	if [[ -n $missing ]]; then
		echo "ERROR: reviewer agents not registered ($context): $missing — the run used generic-agent fallback; see $transcript_file" >&2
		exit 1
	fi
}
