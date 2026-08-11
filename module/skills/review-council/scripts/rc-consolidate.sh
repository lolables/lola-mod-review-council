#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-consolidate.sh <session_dir>
# Applies the model-produced cross-agent consolidation manifest
# (verdicts/_meta/clusters.json) to verdicts/findings.json. Merges each cluster's
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
# Pipeline state the orchestrator writes between phases lives in verdicts/_meta/,
# never in verdicts/ proper — everything that discovers verdicts globs the latter,
# and a phase artifact landing there is exactly RC-4 (clusters.json fed to jq as
# an agent verdict, aborting the run).
manifest="$vdir/_meta/clusters.json"
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

# The merge itself lives in jq/consolidate-clusters.jq — primary selection,
# the fold into provenance.consolidated_from, the REQUEST-CHANGES-wins verdict
# rule, and the jq scoping trap that once deleted every non-primary finding
# (RC-1) are all documented there. It sits in a file rather than inline so
# test-rc-jq-programs.sh can drive it from fixture JSON without building a
# session first, which is the coverage gap that let RC-1 survive.
# Count before and after so the number reported is THIS run's work. The
# document's records accumulate by design (an exact-dedup count from
# verification has to survive), so summing them after the fact reports every
# merge the session has ever made — and the iteration loop in SKILL.md Step 6
# runs this script again on a session that has already been consolidated, where
# that reads as a fresh merge that never happened. The delta is computed here
# rather than exposed as a new document field: verify.md pins the findings.json
# shape and test-consolidation-schema.sh enforces it.
before=$(jq '[.consolidation_records[]?.merged | length] | add // 0' "$findings")
verified_in=$(jq '(.verified // []) | length' "$findings")

result=$(jq --argjson clusters "$clusters" -f "$(dirname "$0")/jq/consolidate-clusters.jq" "$findings")

after=$(echo "$result" | jq '[.consolidation_records[]?.merged | length] | add // 0')
sem=$((after - before))
verified_out=$(echo "$result" | jq '(.verified // []) | length')

# Conservation. Consolidation may only MERGE findings: one that leaves the
# verified array has to be named in a consolidation record's merged[] list, and
# none may appear from nowhere. Checked at runtime rather than left to the
# suite because the failure it catches is silent — RC-1 deleted every finding
# outside the cluster it was reducing while `consolidated` in the success
# message stayed entirely plausible, so the published report was missing a HIGH
# and nothing in the session said so.
#
# The bound is `<=`, not equality. $found in the reducer is built by matching
# every manifest member against the verified array, so a member named twice
# lands in it twice and the merge is declared as two while exactly one finding
# leaves. Over-declaring is a reporting inaccuracy that costs no finding;
# under-declaring is data loss. Only the second is refused here, because an
# equality bound would refuse that manifest — which the model writes, and which
# consolidate-clusters.jq already handles correctly.
#
# findings.json is left exactly as it was, which is why this is a stop rather
# than a degrade: the un-consolidated document is complete and honest, so the
# cost is a report carrying duplicates instead of one quietly missing findings.
removed=$((verified_in - verified_out))
if [[ $removed -lt 0 || $removed -gt $sem ]]; then
	json_output "consolidate_error" \
		"Refusing to write: consolidation took $verified_in verified finding(s) to $verified_out while declaring $sem merged. findings.json is unchanged."
	exit 0
fi

echo "$result" >"$findings"
payload=$(jq -n --argjson s "$sem" '{consolidated:$s}')
json_output "ok" "Consolidated $sem duplicate finding(s)." "$payload"
exit 0
