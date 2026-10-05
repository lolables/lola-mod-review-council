#!/usr/bin/env bash
# Split a Review Council stream-json transcript into the tool-result volume
# context-mode could compress and the volume it could not. Reads stdin,
# prints one JSON object.
#
# Read/Bash/Grep/Glob emit raw bytes context-mode's sandbox tools could have
# reduced to a printed summary — compressible. Agent results are reviewer
# findings, already the dense output of a whole subagent, so counting them as
# compressible would inflate the apparent upside — they land in
# incompressible_bytes along with every other tool's results.
#
# agent_dispatches feeds a separate quantity, M: every dispatch is one more
# agent context paying the fixed tax. It is counted at the tool_use call (the
# point the tax is committed), not at the tool_result, because a transcript
# truncated mid-dispatch would otherwise silently undercount M.
#
# Every failure mode below is guarded explicitly rather than left to fall
# through to a zero, for the same reason ctx-usage-sum.sh guards its own
# fields: these figures feed an arithmetic gate deciding whether to spend
# real money on a live eval matrix, and a plausible-but-wrong number is worse
# than a crash.
#
# A tool_result's content array is only ever sized from blocks of a type we
# understand. "text" carries real bytes. "tool_reference" is the SDK's
# placeholder for a deferred tool listing (e.g. a ToolSearch result) — it is
# metadata, not raw tool output, so it correctly sizes to zero. Anything else
# (an image block, or a type this script hasn't seen yet) is refused rather
# than silently treated as zero bytes: a base64 image block dropped this way
# once produced compressible_bytes: 0 for a real 90+ byte Read result.
#
# Bytes are counted with jq's utf8bytelength, not length: length counts
# codepoints, and the two buckets' text skews differently (Read/Bash/Grep
# output leans ASCII; reviewer prose carries more multi-byte punctuation), so
# codepoint counting would bias the ratio between the two buckets, not just
# their absolute totals.
set -euo pipefail

input="$(cat)"
if [[ -z $input ]]; then
	echo "ERROR: no stream-json on stdin" >&2
	exit 1
fi

out="$(jq -s '
	def result_text:
		if (.content | type) == "string" then .content
		else (.content // [] | map(select(.type == "text") | .text) | join(""))
		end;

	(reduce (.[] | select(.type == "assistant")
	         | .message.content // [] | .[]
	         | select(.type == "tool_use"))
	   as $u ({}; .[$u.id] = $u.name)) as $names

	| [ .[] | select(.type == "user") | .message.content // [] | .[]
	    | select(.type == "tool_result") ] as $tool_results

	| (map(select(.type == "result")) | last) as $result

	| [ $tool_results[]
	    | select((.content | type) == "array")
	    | .content[]
	    | select(.type != "text" and .type != "tool_reference")
	    | .type
	  ] as $bad_block_types

	| if ($tool_results | length) == 0 then
			{error: "no tool results found in transcript"}
		elif (any($tool_results[]; ($names[.tool_use_id] // null) == null)) then
			{error: "tool_result with unresolved tool_use_id — cannot classify its bytes as compressible or not"}
		elif ($bad_block_types | length) > 0 then
			{error: "tool_result content block with unrecognised type(s) \($bad_block_types | unique | join(", ")) — cannot classify its bytes as compressible or not"}
		elif ($result == null) then
			{error: "no result event found in transcript (run may have been aborted)"}
		else
			($tool_results | map({name: $names[.tool_use_id], bytes: (result_text | utf8bytelength)})) as $byname
			| {
					compressible_bytes: (
						[$byname[] | select(.name | IN("Read", "Bash", "Grep", "Glob")) | .bytes]
						| add // 0
					),
					incompressible_bytes: (
						[$byname[] | select(.name | IN("Read", "Bash", "Grep", "Glob") | not) | .bytes]
						| add // 0
					),
					agent_dispatches: ([$names[] | select(. == "Agent")] | length),
					turns: ($result.num_turns // 0)
				}
		end
' <<<"$input")"

err="$(jq -r '.error // empty' <<<"$out")"
if [[ -n "$err" ]]; then
	echo "ERROR: $err" >&2
	exit 1
fi

printf '%s\n' "$out"
