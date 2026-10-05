#!/usr/bin/env bash
# Reduce per-sample {off, on} arm results from ctx-measure-tax.sh's two live
# `claude` probes into the tax figure the pre-screen decision is built on.
# Reads newline-delimited JSON on stdin — one {"off": ..., "on": ...} object
# per sample, each side carrying ctx-usage-sum.sh's fields plus the
# mcp_servers array pulled from that arm's system/init event — and prints one
# JSON object: the per-sample breakdown plus the median fixed_tax_tokens.
#
# The self-check gate lives here, not in the live-run script, because it is
# pure: given the two arms' already-captured JSON, decide whether they
# actually differed the way the experiment requires (off connects nothing,
# on connects context-mode) before trusting any arithmetic on them. A tax
# number computed from arms that were not what they claimed to be is not a
# measurement, so a sample that fails the check aborts the whole reduction —
# same discipline as ctx-usage-sum.sh and ctx-volume-split.sh guarding their
# own failure modes rather than falling through to a plausible-looking zero.
#
# mcp_servers is null (not []) when the caller found no system/init event at
# all — distinct from a real empty array, which means the event was there and
# genuinely connected nothing. Only the former is refused here as a missing
# recording; ctx-measure-tax.sh is where that null actually gets produced,
# when the transcript has no system/init event to mine.
set -euo pipefail

input="$(cat)"
if [[ -z "$input" ]]; then
	echo "ERROR: no sample data on stdin" >&2
	exit 1
fi

out="$(jq -s '
	def sample_error($s; $n):
		if ($s.off.mcp_servers == null) then
			"sample \($n): off arm has no mcp_servers recorded (missing system/init event) — cannot verify it was a clean control"
		elif ($s.on.mcp_servers == null) then
			"sample \($n): on arm has no mcp_servers recorded (missing system/init event) — cannot verify context-mode connected"
		elif ($s.off.mcp_servers | length) != 0 then
			"sample \($n): off arm connected \($s.off.mcp_servers | length) MCP server(s) (\($s.off.mcp_servers | tostring)) — not a clean control"
		elif ([$s.on.mcp_servers[] | select(.name == "plugin_context-mode_context-mode")] | length) == 0 then
			"sample \($n): on arm did not connect plugin_context-mode_context-mode (\($s.on.mcp_servers | tostring)) — treatment arm did not load context-mode"
		else
			null
		end;

	. as $samples
	| ([range(0; ($samples | length)) as $i | sample_error($samples[$i]; $i + 1)]
		| map(select(. != null)) | first) as $err

	| if ($samples | length) == 0 then
			{error: "no sample data on stdin"}
		elif ($err != null) then
			{error: $err}
		else
			($samples | map({
				prefix_off: .off.prefix_tokens,
				prefix_on: .on.prefix_tokens,
				fixed_tax_tokens: (.on.prefix_tokens - .off.prefix_tokens),
				cost_off: .off.total_cost_usd,
				cost_on: .on.total_cost_usd,
				mcp_servers_off: .off.mcp_servers,
				mcp_servers_on: .on.mcp_servers
			})) as $results
			| {
					samples: $results,
					median_fixed_tax_tokens: (
						[$results[].fixed_tax_tokens] | sort as $sorted
						| ($sorted | length) as $n
						| if ($n % 2) == 1 then $sorted[$n / 2 | floor]
							else (($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2)
							end
					)
				}
		end
' <<<"$input")"

err="$(jq -r '.error // empty' <<<"$out")"
if [[ -n "$err" ]]; then
	echo "ERROR: $err" >&2
	exit 1
fi

printf '%s\n' "$out"
