#!/usr/bin/env bash
# Reduce a Claude Code stream-json transcript to the token figures this eval
# compares. Reads stdin, prints one JSON object.
#
# prefix_tokens is the first assistant turn's input + cache_creation +
# cache_read. That turn carries the system prompt, tool schemas and hook
# injections, which is the fixed cost context-mode adds to every agent
# context — the quantity the pre-screen is built to measure. Later turns
# re-read that same prefix, so measuring it once and multiplying is both
# cheaper and less noisy than summing whole runs.
#
# Every failure mode below is guarded explicitly rather than left to fall
# through to a zero, because these figures feed an arithmetic gate deciding
# whether to spend real money on a live eval matrix: a plausible-but-wrong
# number is worse than a crash. A truncated capture, an auth failure, or a
# killed run must all be loud, not read as "context-mode is free".
set -euo pipefail

input="$(cat)"
if [[ -z "$input" ]]; then
	echo "ERROR: no stream-json on stdin" >&2
	exit 1
fi

# The old whitespace-only check here (${input//[[:space:]]/}) copied the
# whole buffer to answer a question the jq pass below now answers for free:
# stdin that is nothing but blank lines parses under `jq -s` as an empty
# array, which trips the "no assistant events found" guard. Duplicating that
# check at the bash layer cost a full scan of the buffer on every run,
# including the 11 MB common case, to catch a case already caught downstream
# with a more specific message.
out="$(jq -s '
	def usage_of: .message.usage;
	(map(select(.type == "assistant")) | first) as $first_event
	| (map(select(.type == "result")) | last) as $result
	| if ($first_event == null) then
			{error: "no assistant events found in transcript"}
		elif (($first_event | usage_of) == null) then
			{error: "first assistant event has no usage block — refusing to substitute a later turn"}
		elif ($result == null) then
			{error: "no result event found in transcript (run may have been aborted)"}
		else
			($first_event | usage_of) as $first
			| {
					prefix_tokens: (
						($first.input_tokens // 0)
						+ ($first.cache_creation_input_tokens // 0)
						+ ($first.cache_read_input_tokens // 0)
					),
					total_output: ($result.usage.output_tokens // 0),
					total_cache_read: ($result.usage.cache_read_input_tokens // 0),
					turns: ($result.num_turns // 0),
					total_cost_usd: ($result.total_cost_usd // 0)
				}
		end
' <<<"$input")"

err="$(jq -r '.error // empty' <<<"$out")"
if [[ -n "$err" ]]; then
	echo "ERROR: $err" >&2
	exit 1
fi

printf '%s\n' "$out"
