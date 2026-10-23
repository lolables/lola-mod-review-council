#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-recompute-verdicts.sh <session_dir>
# Derives each agent's verdict in verdicts/findings.json `.verdicts` from the
# findings left and the verdict that agent filed (verdicts/verdicts-map.json,
# which rc-verify-evidence.sh writes beside findings.json). The rules live in
# jq/recompute-verdicts.jq; this script owns the inputs, the write and the log.
#
# After the evidence check built the map, nothing wrote it again: the
# orchestrator applied the upgrade and REQUEST CHANGES rules by hand-edit, and
# both renderers print the map as is (#52). Run it as verify.md Step 6, after
# validation. After Disposition, rc-check-disposition.sh applies the same
# program before it records the hash the render gate checks.
#
# Every agent whose entry changes is listed in the `changes` payload, each with
# the rule that set it, for verification.txt. A map that already follows from
# the findings leaves findings.json untouched, so a re-run changes nothing.
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
if (($# > 1)); then
	json_output "validation_error" "Unknown argument: ${2}. Usage: rc-recompute-verdicts.sh <session_dir>"
	exit 0
fi

vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
declared_file="$vdir/verdicts-map.json"
[[ -f "$findings" ]] || {
	json_output "nothing_to_do" "No findings.json found, so there are no verdicts to recompute."
	exit 0
}
if ! jq -se 'length == 1' "$findings" >/dev/null 2>&1; then
	json_output "validation_error" "findings.json is not valid JSON (one document); findings.json is unchanged."
	exit 0
fi
if [[ ! -f "$declared_file" ]] || ! jq -se 'length == 1' "$declared_file" >/dev/null 2>&1; then
	json_output "validation_error" \
		"No readable verdicts/verdicts-map.json (the verdicts the reviewers filed), so the per-agent verdicts cannot be derived. Re-run rc-verify-evidence.sh, which writes it, then Verification's later steps in order; findings.json is unchanged."
	exit 0
fi

declared=$(jq -c . "$declared_file")
result=$(jq --argjson declared "$declared" -f "$(dirname "$0")/jq/recompute-verdicts.jq" "$findings")
problem=$(jq -r '.problem // empty' <<<"$result")
if [[ -n "$problem" ]]; then
	json_output "validation_error" "Cannot recompute verdicts: ${problem}. findings.json is unchanged."
	exit 0
fi

# Agent names and the values they replace come from files a hand edit could
# have written, and the message reaches the orchestrator: truncated and quoted,
# as rc-check-disposition.sh does with finding ids.
payload=$(jq '{changes: [.changes[] | {agent: (.agent | .[:64]),
	from: (.from | if type == "string" then .[:64] else . end), to, rule}]}' <<<"$result")
changed=$(jq '.changes | length' <<<"$payload")
if ((changed == 0)); then
	json_output "ok" "Per-agent verdicts already follow from the findings; findings.json is unchanged." "$payload"
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

listing=$(jq -r '.changes | map("\(.agent | tojson): \(.from | tojson) -> \(.to // "removed") (\(.rule))") | join("; ")' <<<"$payload")
json_output "ok" "Per-agent verdicts recomputed: ${listing}. Log each change in verification.txt (verify.md Step 6)." "$payload"
exit 0
