#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-apply-severity-override.sh <session_dir>
# Applies the project's `Severity override` to the verified findings in
# verdicts/findings.json (#121). The rules live in jq/severity-override.jq;
# this script owns the inputs, the write and the status.
#
# The override comes from tracking.md, where rc-prepare.sh wrote it normalised
# from the base revision's configuration block, so a change cannot loosen its
# own review. It is re-validated here anyway: tracking.md is a file in the
# session, and a hand-edited term that no longer parses must stop the run
# rather than be half-applied.
#
# Runs at every effort immediately before rc-recompute-verdicts.sh, so
# per-agent verdicts and the council verdict see the adjusted levels. The
# severity pack shapes how reviewers and the arbiter rate; this bounds the
# result, so the configuration wins.
#
# A finding already within its bound is left untouched and findings.json is
# not rewritten, so a re-run changes nothing (test-rc-idempotency.sh).
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
if (($# > 1)); then
	json_output "validation_error" "Unknown argument: ${2}. Usage: rc-apply-severity-override.sh <session_dir>"
	exit 0
fi

vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
[[ -f "$findings" ]] || {
	json_output "nothing_to_do" "No findings.json found, so there is nothing to override."
	exit 0
}
override=$(rc_parse_kv "$session_dir/tracking.md" "Severity override")
if [[ -z "$override" || "$override" == "none" ]]; then
	json_output "nothing_to_do" "No Severity override is configured; findings.json is unchanged."
	exit 0
fi

# The normalised form only: `persona OP LEVEL` with no spaces, joined by ", ",
# one term per persona. Anything else did not come from rc-prepare.sh.
term_re='^(adversary|curator|guard|sre|testing)(<=|>=|=)(CRITICAL|HIGH|MEDIUM|LOW)$'
terms='{}'
declare -A seen=()
IFS=',' read -r -a parts <<<"$override"
for part in "${parts[@]}"; do
	part="${part#"${part%%[![:space:]]*}"}"
	persona=""
	[[ ! "$part" =~ $term_re ]] || persona="${BASH_REMATCH[1]}"
	if [[ -z "$persona" || -n "${seen[$persona]:-}" ]]; then
		json_output "validation_error" \
			"tracking.md's Severity override term '${part:0:64}' is not in the form rc-prepare.sh writes (persona OP LEVEL, one term per persona). Re-run preparation; findings.json is unchanged."
		exit 0
	fi
	seen["$persona"]=1
	terms=$(jq -c --arg p "$persona" --arg op "${BASH_REMATCH[2]}" --arg level "${BASH_REMATCH[3]}" --arg term "$part" \
		'.[$p] = {op: $op, level: $level, term: $term}' <<<"$terms")
done

if ! jq -se 'length == 1 and (.[0] | type == "object"
	and ((.verified // []) | type == "array")
	and all((.verified // [])[]; type == "object"
		and (.severity | IN("CRITICAL", "HIGH", "MEDIUM", "LOW"))
		and ((.provenance // {}) | type == "object")
		and ((.provenance.calibrated_from? // []) | type == "array")))' "$findings" >/dev/null 2>&1; then
	json_output "validation_error" \
		"findings.json is not a valid findings document (one JSON object; every verified finding an object with a CRITICAL, HIGH, MEDIUM or LOW severity and an object provenance). findings.json is unchanged."
	exit 0
fi

result=$(jq --argjson terms "$terms" -f "$(dirname "$0")/jq/severity-override.jq" "$findings")

# Ids and agent names come from a file a hand edit could have written, and the
# message reaches the orchestrator: truncated, as rc-recompute-verdicts.sh does.
payload=$(jq '{changes: [.changes[] | {id: (.id | if type == "string" then .[:64] else . end),
	agent: (.agent | .[:64]), from, to, term}]}' <<<"$result")
changed=$(jq '.changes | length' <<<"$payload")
if ((changed == 0)); then
	json_output "ok" "Every finding is already within the Severity override (${override}); findings.json is unchanged." "$payload"
	exit 0
fi

# Built beside findings.json and renamed over it, so a jq that dies leaves the
# previous file rather than a truncated one (#82).
findings_tmp=""
trap '[[ -z "$findings_tmp" ]] || rm -f "$findings_tmp"' EXIT
findings_tmp=$(mktemp "$vdir/.findings.XXXXXX")
jq '.doc' <<<"$result" >"$findings_tmp"
mv -f "$findings_tmp" "$findings"
findings_tmp=""

listing=$(jq -r '.changes | map("\(.id | tojson) \(.agent | tojson): \(.from) -> \(.to) (\(.term))") | join("; ")' <<<"$payload")
json_output "ok" "Severity override applied: ${listing}. Log each change under SEVERITY CALIBRATION in verification.txt (verify.md Step 4b)." "$payload"
exit 0
