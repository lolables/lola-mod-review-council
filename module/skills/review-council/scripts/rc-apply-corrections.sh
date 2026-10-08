#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-apply-corrections.sh <session_dir> [review_root]
# Applies the correction round (verify.md Step 1) to verdicts/findings.json,
# keyed on finding id. The orchestrator records each agent's reply in
# verdicts/_meta/corrections.json:
#
#   {"results": [{"id": "F2", "outcome": "CORRECTED", "evidence": "...", "line": 12},
#                {"id": "F3", "outcome": "WITHDRAWN"}]}
#
# `line` is optional and replaces the cited line. Every correctable finding
# then leaves `correctable`:
#   CORRECTED, and the new quote passes the same matcher rc-verify-evidence.sh
#     ran (lib/evidence.sh)          -> verified, keeping its id
#   CORRECTED, and it still fails    -> stripped, reason CORRECTION_FAILED
#   WITHDRAWN                        -> removed (withdrawn, not stripped)
#   no entry                         -> stripped, reason NO_CORRECTION
# Promoted findings are deduplicated against the verified set again.
#
# The re-check is the point of the script. Moved by hand, a correction that
# still did not match the source reached the report as verified evidence.
#
# Any malformed entry, or one naming a finding that is not correctable, refuses
# the whole pass with findings.json unchanged, so a transcription slip is fixed
# and re-run rather than costing a finding its one correction.

session_dir="${1:-}"
review_root="${2:-${REVIEW_ROOT:-.}}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
results_file="$vdir/_meta/corrections.json"
[[ -f "$findings" ]] || {
	json_output "nothing_to_do" "No findings.json found."
	exit 0
}
if ! jq -e 'type == "object" and all(.verified, .correctable, .stripped; (. // []) | type == "array")
	and ([(.verified // [])[], (.correctable // [])[], (.stripped // [])[] | .id]
		| all(type == "string") and length == (unique | length))' "$findings" >/dev/null 2>&1; then
	json_output "correction_error" "findings.json is not a findings document with unique string ids (a hand edit after verification?); findings.json is unchanged."
	exit 0
fi
n=$(jq '(.correctable // []) | length' "$findings")
if [[ "$n" -eq 0 ]]; then
	json_output "nothing_to_do" "No correctable findings; the correction round has nothing to apply."
	exit 0
fi

if [[ ! -f "$results_file" ]]; then
	json_output "correction_error" "No verdicts/_meta/corrections.json. Record each agent's reply there and re-run; to strip every correctable finding as unanswered, write {\"results\": []}. findings.json is unchanged."
	exit 0
fi
# corrections.json is transcribed by the orchestrator from agent replies, so
# every entry is checked before any is applied.
problem=$(jq -r --slurpfile f "$findings" '
	if type != "object" or (.results | type) != "array" then "it has no results array"
	else
		[$f[0].correctable[].id] as $ids
		| [.results[] | .id] as $named
		| [ .results[] as $r
		  | if ($r | type) != "object" or ($r.id | type) != "string" then "an entry is not an object with a string id"
		    elif ($ids | index($r.id)) == null then "\($r.id) is not a correctable finding"
		    elif $r.outcome == "WITHDRAWN" then
		      (if ($r | keys) - ["id", "outcome"] != [] then "\($r.id): a withdrawal carries only id and outcome" else empty end)
		    elif $r.outcome != "CORRECTED" then "\($r.id): outcome must be CORRECTED or WITHDRAWN"
		    elif ($r | keys) - ["id", "outcome", "evidence", "line"] != [] then "\($r.id): only evidence and line may be corrected"
		    elif ($r.evidence | type) != "string" or $r.evidence == "" then "\($r.id): CORRECTED needs a non-empty evidence string"
		    elif $r.line != null and (($r.line | type) != "number" or $r.line != ($r.line | floor) or $r.line < 1 or $r.line > 10000000)
		      then "\($r.id): line must be a whole number from 1 to 10000000"
		    else empty end ]
		+ (if ($named | length) != ($named | unique | length) then ["a finding is answered twice"] else [] end)
		| first // empty
	end' "$results_file" 2>/dev/null) || problem="it is not valid JSON"
if [[ -n "$problem" ]]; then
	json_output "correction_error" "corrections.json refused: ${problem}. Nothing was applied; findings.json is unchanged."
	exit 0
fi

root_abs=$(cd "$review_root" 2>/dev/null && pwd -P) || {
	json_output "nothing_to_do" "Review root does not exist: $review_root"
	exit 0
}
# shellcheck source=module/skills/review-council/scripts/lib/evidence.sh
source "$(dirname "$0")/lib/evidence.sh"

promoted='[]'
failed='[]'
withdrawn='[]'
unanswered='[]'
for ((i = 0; i < n; i++)); do
	obj=$(jq -c ".correctable[$i]" "$findings")
	id=$(jq -r '.id' <<<"$obj")
	r=$(jq -c --arg id "$id" '[.results[] | select(.id == $id)] | first // empty' "$results_file")
	if [[ -z "$r" ]]; then
		unanswered=$(jq --argjson o "$obj" '. + [$o + {status: "stripped", reason: "NO_CORRECTION"}]' <<<"$unanswered")
		continue
	fi
	outcome=$(jq -r '.outcome' <<<"$r")
	if [[ "$outcome" == "WITHDRAWN" ]]; then
		withdrawn=$(jq --arg id "$id" '. + [$id]' <<<"$withdrawn")
		continue
	fi
	candidate=$(jq -c --argjson r "$r" '. as $o
		| .evidence = $r.evidence | .line = ($r.line // $o.line)
		| .provenance.correction = {from: {evidence: $o.evidence, line: $o.line}, reason: $o.reason}' <<<"$obj")
	file=$(jq -r '.file' <<<"$candidate")
	line=$(jq -r '.line // ""' <<<"$candidate")
	ev=$(jq -r '.evidence' <<<"$candidate")
	check=$(rc_evidence_status "$file" "$line" "$ev")
	if [[ "$check" == "verified" ]]; then
		promoted=$(jq --argjson o "$candidate" '. + [$o + {status: "verified"} | del(.reason)]' <<<"$promoted")
	else
		failed=$(jq --argjson o "$obj" --argjson r "$r" --arg c "$check" '. + [$o + {status: "stripped", reason: "CORRECTION_FAILED"}
			| .provenance.correction = {attempted: {evidence: $r.evidence, line: ($r.line // $o.line)}, reason: $o.reason, check: $c}]' <<<"$failed")
	fi
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s' "$promoted" >"$work/promoted.json"
printf '%s' "$failed" >"$work/failed.json"
printf '%s' "$unanswered" >"$work/unanswered.json"
jq --slurpfile promoted "$work/promoted.json" '(.verified // []) + $promoted[0]' "$findings" >"$work/merged.json"
jq -f "$(dirname "$0")/jq/dedup-findings.jq" "$work/merged.json" >"$work/verified.json"
merged=$(jq 'length' "$work/merged.json")
kept=$(jq 'length' "$work/verified.json")
dedup=$((merged - kept))
jq --slurpfile verified "$work/verified.json" --slurpfile failed "$work/failed.json" \
	--slurpfile unanswered "$work/unanswered.json" --argjson dedup "$dedup" \
	'.verified = $verified[0] | .correctable = []
	 | .stripped = ((.stripped // []) + $failed[0] + $unanswered[0])
	 | .duplicates_consolidated = ((.duplicates_consolidated // 0) + $dedup)' \
	"$findings" >"$work/findings.json"
# Redirect into the existing file, as the other phase scripts do, so it keeps
# its mode rather than taking mktemp's 0600.
cat "$work/findings.json" >"$findings"

payload=$(jq -n --argjson p "$promoted" --argjson f "$failed" --argjson w "$withdrawn" \
	--argjson u "$unanswered" --argjson d "$dedup" \
	'{verified: [$p[].id], stripped: [$f[].id], withdrawn: $w, unanswered: [$u[].id], duplicates_consolidated: $d}')
summary=$(jq -r '"\(.verified | length) verified, \(.stripped | length) failed and stripped, \(.withdrawn | length) withdrawn, \(.unanswered | length) unanswered and stripped"' <<<"$payload")
json_output "ok" "Correction round applied: ${summary}." "$payload"
exit 0
