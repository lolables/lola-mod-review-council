#!/usr/bin/env bash
# Measure the fixed per-context token cost context-mode adds, by running the
# same trivial prompt with and without it and diffing the first-turn prefix.
#
# The prompt is deliberately trivial: any real work would add variable tool
# output and drown the fixed cost being measured. Both arms run with a clean,
# per-sample CLAUDE_CONFIG_DIR so neither inherits the operator's own plugin
# set, and the "off" arm gets no --settings/--mcp-config at all — see the
# CONTROL-ARM WARNING in ctx-mode-config.sh for why a flagless run against a
# non-isolated dir is not a clean control on this host.
#
# Prefix tokens vary with cache state, so this takes several samples and
# reports the median alongside every raw value — a single sample would let
# one noisy run masquerade as the answer.
#
# stderr is never discarded. A `claude` invocation that fails (auth, network,
# a missing model) must abort the whole measurement loudly, not fall through
# to ctx-usage-sum.sh's guards and print a number that looks plausible but
# measures nothing.
#
# Each arm's transcript is also mined for its `system`/`init` event's
# mcp_servers array and carried through to the final output. A tax number
# with no proof the two arms actually differed is not evidence, it's a
# coincidence with a JSON wrapper — so ctx-tax-reduce.sh asserts on it: the
# off arm must connect no MCP servers, and the on arm must connect
# plugin_context-mode_context-mode, or the reduction aborts instead of
# reporting a number for arms that were not what they claimed to be. That
# check lives in ctx-tax-reduce.sh, not here and not in ctx-usage-sum.sh: it
# is pure (it only ever looks at JSON already on disk, never the network),
# which is what makes it unit-testable with fixtures the way
# ctx-usage-sum.sh and ctx-volume-split.sh already are. This script's job is
# only to run the two live probes and hand their output to that filter.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT="${CTX_TAX_PROMPT:-Reply with exactly: ok}"
MODEL="${CTX_TAX_MODEL:-claude-sonnet-4-6}"
SAMPLES="${CTX_TAX_SAMPLES:-3}"

if ! [[ $SAMPLES =~ ^[0-9]+$ ]] || [[ $SAMPLES -lt 1 ]]; then
	echo "ERROR: CTX_TAX_SAMPLES must be a positive integer, got '$SAMPLES'" >&2
	exit 1
fi

# Auth seeding (seed_auth) and the claude exit-status/stderr failure guard
# (check_claude_result) are shared with ctx-hook-probe.sh — both scripts make
# live `claude` invocations under an isolated CLAUDE_CONFIG_DIR and hit the
# same "Not logged in" wall and the same need to abort loudly on failure. See
# lib/live-claude.sh for the rationale.
# shellcheck source=.lola-eval/analysis/scripts/lib/live-claude.sh
source "$SCRIPT_DIR/lib/live-claude.sh"

work="$(mktemp -d)"
samples_file="$(mktemp)"
trap 'rm -rf "$work" "$samples_file"' EXIT
"$SCRIPT_DIR/ctx-mode-config.sh" "$work"

# Runs one `claude -p` call, reduces it via ctx-usage-sum.sh, and merges in
# the mcp_servers array from the transcript's system/init event (null if no
# such event is found — ctx-tax-reduce.sh is what refuses that, since judging
# whether a missing recording invalidates the sample is the self-check's job,
# not this function's). stderr is captured (not discarded) so a failure can
# be reported with the CLI's own diagnostic instead of silently producing a
# number. The transcript is written to a file rather than held in a variable
# so it can be scanned twice — once by ctx-usage-sum.sh, once for
# mcp_servers — without spawning `claude` twice.
#
# Both temp files are created under $work via `mktemp -p`, not the default
# tmp dir, purely so the top-level `trap ... EXIT` already cleaning up $work
# also catches them on every exit path — including a `jq` failure between
# here and the final `rm -f`, which would otherwise orphan a file that no
# code path after the failure point ever reaches. The `rm -f` calls below are
# then hygiene for the common (successful) case, not the last line of
# defense.
run_arm() { # config_dir extra_args...
	local config_dir="$1"
	shift
	seed_auth "$config_dir"

	local transcript_file stderr_file
	transcript_file="$(mktemp -p "$work")"
	stderr_file="$(mktemp -p "$work")"
	local status=0
	CLAUDE_CONFIG_DIR="$config_dir" \
		claude -p "$PROMPT" --model "$MODEL" \
		--output-format stream-json --verbose \
		--permission-mode bypassPermissions \
		"$@" >"$transcript_file" 2>"$stderr_file" || status=$?

	check_claude_result "$status" "$stderr_file" "config dir $config_dir"

	local usage
	usage="$("$SCRIPT_DIR/ctx-usage-sum.sh" <"$transcript_file")"

	local mcp_servers
	mcp_servers="$(jq -cs '
		(map(select(.type == "system" and .subtype == "init")) | first) as $init
		| if $init == null then null else ($init.mcp_servers // []) end
	' "$transcript_file")"

	rm -f "$transcript_file" "$stderr_file"

	jq -n --argjson usage "$usage" --argjson mcp "$mcp_servers" '$usage + {mcp_servers: $mcp}'
}

for ((i = 1; i <= SAMPLES; i++)); do
	off="$(run_arm "$work/cfg-off-$i")"
	on="$(run_arm "$work/cfg-on-$i" \
		--settings "$work/settings.json" --mcp-config "$work/mcp.json" \
		--strict-mcp-config)"

	pair="$(jq -nc --argjson off "$off" --argjson on "$on" '{off: $off, on: $on}')"

	# Run this sample through the self-check immediately (on its own, a
	# one-element array) rather than waiting for the batch reduction below —
	# a bad config aborts here, before SAMPLES-i more paid `claude` calls run
	# only to be discarded once the aggregate reduction rejects them anyway.
	printf '%s\n' "$pair" | "$SCRIPT_DIR/ctx-tax-reduce.sh" >/dev/null

	printf '%s\n' "$pair" >>"$samples_file"
done

"$SCRIPT_DIR/ctx-tax-reduce.sh" <"$samples_file"
