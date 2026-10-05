#!/usr/bin/env bash
# Reduce a Claude Code stream-json transcript to the context-mode routing
# rate: the fraction of tool calls that went through context-mode's own MCP
# tools (`mcp__plugin_context-mode_context-mode__*`) rather than a native
# tool (Read, Bash, Grep, Agent, ...). Reads stdin, prints one JSON object.
#
# This is the headline number the adoption probe reports: production logs
# measured 3.34% of tool calls routed through context-mode when it was
# installed and connected. This script computes the same ratio for a
# deliberately configured arm so the two are directly comparable.
#
# Counted at the tool_use call (the assistant's request to invoke a tool),
# not the tool_result, for the same reason ctx-volume-split.sh counts
# agent_dispatches there: a transcript truncated mid-call (budget cap,
# aborted run) would otherwise silently undercount the denominator along
# with the numerator, which could hide a truncation behind a plausible-looking
# rate. A denominator of zero real tool calls is refused outright, below.
#
# Every failure mode is guarded explicitly rather than left to fall through
# to a zero or a divide-by-zero, mirroring ctx-usage-sum.sh and
# ctx-volume-split.sh: a plausible-but-wrong routing rate is worse than a
# crash, since this number is the one deciding whether a $60 eval matrix
# runs.
set -euo pipefail

input="$(cat)"
if [[ -z $input ]]; then
	echo "ERROR: no stream-json on stdin" >&2
	exit 1
fi

out="$(jq -s '
	def is_context_mode_tool:
		startswith("mcp__plugin_context-mode_context-mode__");

	[ .[] | select(.type == "assistant")
	  | .message.content // [] | .[]
	  | select(.type == "tool_use") | .name
	] as $tool_use_names

	| (map(select(.type == "result")) | last) as $result

	| if ($tool_use_names | length) == 0 then
			{error: "no tool calls found in transcript"}
		elif ($result == null) then
			{error: "no result event found in transcript (run may have been aborted)"}
		else
			($tool_use_names | reduce .[] as $n ({}; .[$n] = ((.[$n] // 0) + 1))) as $histogram
			| ([$tool_use_names[] | select(is_context_mode_tool)] | length) as $ctx_calls
			| ($tool_use_names | length) as $total_calls
			| {
					total_tool_calls: $total_calls,
					context_mode_tool_calls: $ctx_calls,
					routing_rate: ($ctx_calls / $total_calls),
					tool_histogram: $histogram
				}
		end
' <<<"$input")"

err="$(jq -r '.error // empty' <<<"$out")"
if [[ -n "$err" ]]; then
	echo "ERROR: $err" >&2
	exit 1
fi

printf '%s\n' "$out"
