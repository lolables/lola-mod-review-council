#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-consolidate.sh <session_dir>
# Applies the model-produced cross-agent consolidation manifest
# (verdicts/clusters.json) to verdicts/findings.json. Merges each cluster's
# members into a single primary finding (highest severity), folds secondary
# angles into primary.provenance.consolidated_from, and updates
# duplicates_consolidated (exact + semantic) and consolidation_records.
# No-op when the manifest is absent or has no clusters.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
manifest="$vdir/clusters.json"
[[ -f "$findings" ]] || {
	json_output "nothing_to_do" "No findings.json found."
	exit 0
}

clusters='[]'
[[ -f "$manifest" ]] && clusters=$(jq -c '.clusters // []' "$manifest" 2>/dev/null || echo '[]')
cluster_count=$(echo "$clusters" | jq 'length')
if [[ "$cluster_count" -eq 0 ]]; then
	payload=$(jq -n '{consolidated:0}')
	json_output "ok" "No clusters to consolidate." "$payload"
	exit 0
fi

result=$(jq --argjson clusters "$clusters" '
	def rank: {"CRITICAL":5,"HIGH":4,"MEDIUM":3,"LOW":2,"INFO":1}[.] // 0;
	def ident: {file:.file, line:.line, agent:.agent};
	. as $root
	| (reduce $clusters[] as $c (
		{verified: ($root.verified // []), records: [], semantic: 0};
		( [ $c.members[] as $m | .verified[]
			| select(.file==$m.file and .line==$m.line and .agent==$m.agent) ] ) as $found
		| if ($found | length) < 2 then .
		  else
			( $found | sort_by([ (.severity|rank), (.evidence|length), .agent ]) | last ) as $primary
			| ( $found | map(select(ident != ($primary|ident))) ) as $secs
			| ( $secs | map({agent, severity, angle:.description, recommendation}) ) as $folded
			| ( if ($found | any(.verdict=="REQUEST CHANGES")) then "REQUEST CHANGES" else $primary.verdict end ) as $verdict
			| ( $primary + {verdict:$verdict}
				+ {provenance: (($primary.provenance // {})
					+ {consolidated_from: (($primary.provenance.consolidated_from // []) + $folded)})} ) as $newprimary
			| ( [ $secs[] | ident ] ) as $secids
			# `any(f)` rebinds `.` to each element of its input, so a bare
			# `ident` inside it would be evaluated against the $secids element
			# rather than the finding being filtered — reducing the test to
			# `secid == secid`, always true, which deletes every non-primary
			# finding in the array. Capture the finding as $f at the boundary.
			| .verified = ( [ .verified[] | . as $f
				| if (($f|ident) == ($primary|ident)) then $newprimary
				  elif ($secids | any(. == ($f|ident))) then empty
				  else . end ] )
			| .records += [ {primary: ($primary|ident), merged: $secids} ]
			| .semantic += ($secs | length)
		  end
	)) as $acc
	| $root
		+ {verified: $acc.verified}
		+ {duplicates_consolidated: (($root.duplicates_consolidated // 0) + $acc.semantic)}
		+ {consolidation_records: (($root.consolidation_records // []) + $acc.records)}
' "$findings")

echo "$result" >"$findings"
sem=$(echo "$result" | jq '[.consolidation_records[].merged | length] | add // 0')
payload=$(jq -n --argjson s "$sem" '{consolidated:$s}')
json_output "ok" "Consolidated $sem duplicate finding(s)." "$payload"
exit 0
