#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-apply-validation.sh <session_dir> [--final] [--dispute F1,F2,...]
# Applies the validation gate's outcomes (verdicts/_meta/validation.json, the
# validator's reply saved verbatim) to verdicts/findings.json, keyed on finding
# id. The rules live in jq/apply-validation.jq; this script owns the inputs,
# the conservation check and the status.
#
# Two passes, so the validator gets exactly one retry. The first pass applies
# what it accepts and returns `retry` naming every verified finding still
# without an outcome. The orchestrator re-asks the validator about those ids,
# overwrites validation.json, and runs the --final pass, which applies what it
# accepts and marks the rest UNVALIDATED. --dispute names findings whose
# RETRACTED outcome the orchestrator judged unsupported (evidence that does
# not contradict the finding): that outcome is rejected as DISPUTED, so the
# finding stays pending, then UNVALIDATED, and is never silently dropped. The
# pass is an argument rather than a counter kept in findings.json because
# every phase script must leave state unchanged when re-run on its own output
# (test-rc-idempotency.sh) — a counter would turn a re-run of the first pass
# into the second.
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
final=false
disputed='[]'
have_dispute=false
usage="Usage: rc-apply-validation.sh <session_dir> [--final] [--dispute F1,F2,...]"
shift
while (($# > 0)); do
	case "$1" in
	--final)
		if $final; then
			json_output "validation_error" "Repeated argument: --final. ${usage}"
			exit 0
		fi
		final=true
		shift
		;;
	--dispute)
		if $have_dispute || [[ ! "${2:-}" =~ ^F[0-9]+(,F[0-9]+)*$ ]]; then
			json_output "validation_error" "--dispute takes one comma-separated list of finding ids such as F3,F7. ${usage}"
			exit 0
		fi
		have_dispute=true
		disputed=$(jq -Rc 'split(",")' <<<"$2")
		shift 2
		;;
	*)
		json_output "validation_error" "Unknown argument: ${1}. ${usage}"
		exit 0
		;;
	esac
done

vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
results_file="$vdir/_meta/validation.json"
[[ -f "$findings" ]] || {
	json_output "nothing_to_do" "No findings.json found."
	exit 0
}
if ! jq -e 'type == "object" and ((.verified // []) | type == "array")
	and ((.stripped // []) | type == "array")' "$findings" >/dev/null 2>&1; then
	json_output "validation_error" "findings.json is not a valid findings document; findings.json is unchanged."
	exit 0
fi
if ! jq -e '(.verified // []) | all(.id | type == "string")' "$findings" >/dev/null; then
	json_output "validation_error" \
		"findings.json has verified findings without an id, so no outcome can be tied to them. Ids were lost after verification (a hand edit in Steps 1-3c). Stop and report; findings.json is unchanged."
	exit 0
fi

if ! jq -e '[(.verified // [])[], (.stripped // [])[] | .id | select(. != null)]
	| length == (unique | length)' "$findings" >/dev/null; then
	json_output "validation_error" \
		"findings.json has duplicate finding ids, so outcomes cannot be tied to one finding. Ids were duplicated after verification (a hand edit in Steps 1-3c). Stop and report; findings.json is unchanged."
	exit 0
fi

# A dispute naming no finding is a typo for one that does, and the retraction it
# was meant to stop would otherwise be applied. Refused before anything is, and
# checked against every id rather than pending ones so that re-running a pass on
# its own output (ids now final) still behaves the same.
unknown_disputes=$(jq -r --argjson disputed "$disputed" \
	'[(.verified // [])[], (.stripped // [])[] | .id] as $ids
	| [$disputed[] | select(. as $d | $ids | index($d) | not)] | join(",")' "$findings")
if [[ -n "$unknown_disputes" ]]; then
	json_output "validation_error" \
		"--dispute names ${unknown_disputes}, which is not a finding id. Nothing was applied; findings.json is unchanged."
	exit 0
fi

# A missing or unparsable reply is no outcomes, not a failure: every finding
# stays pending, and the retry is exactly the recovery it needs.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
note=""
if [[ ! -f "$results_file" ]]; then
	note=" No validation.json was found, so no outcomes were applied."
	: >"$work/results.json"
elif ! jq -e . "$results_file" >/dev/null 2>&1; then
	note=" validation.json is not valid JSON, so no outcomes were applied."
	: >"$work/results.json"
elif ! jq -ce 'if type == "object" and (.results | type) == "array" then .results else empty end' \
	"$results_file" >"$work/results.json"; then
	note=" validation.json has no results array, so no outcomes were applied."
	: >"$work/results.json"
fi

result=$(jq --slurpfile results "$work/results.json" --argjson final "$final" --argjson disputed "$disputed" \
	-f "$(dirname "$0")/jq/apply-validation.jq" "$findings")

# Conservation: validation may only move a finding from verified to stripped,
# and only by retracting it. Anything else is a reducer bug, and writing its
# output would publish a report missing findings nobody retracted.
# The unique-id precondition above makes this unreachable by any input, so no
# test exercises it; it stays as defence in depth against a reducer change.
verified_in=$(jq '(.verified // []) | length' "$findings")
stripped_in=$(jq '(.stripped // []) | length' "$findings")
verified_out=$(jq '.doc.verified | length' <<<"$result")
stripped_out=$(jq '.doc.stripped | length' <<<"$result")
retracted=$(jq '.report.retracted_now | length' <<<"$result")
if ((verified_out + retracted != verified_in || stripped_out != stripped_in + retracted)); then
	json_output "validation_error" \
		"Refusing to write: validation took $verified_in verified finding(s) to $verified_out while retracting $retracted. findings.json is unchanged."
	exit 0
fi

jq '.doc' <<<"$result" >"$findings"

payload=$(jq '.report | {confirmed: (.confirmed | length), corrected: (.corrected | length),
	retracted: (.retracted | length), rejected, pending, unvalidated}' <<<"$result")
summary=$(jq -r '"\(.confirmed) confirmed, \(.corrected) corrected, \(.retracted) retracted, \(.rejected | length) rejected, \(.unvalidated | length) unvalidated"' <<<"$payload")
pending=$(jq -r '.pending | join(" ")' <<<"$payload")
if [[ -n "$pending" ]]; then
	json_output "retry" "Validation applied: ${summary}.${note} Re-ask the validator about ${pending} only, overwrite validation.json with its reply, then run again with --final (add --dispute for any retraction still unsupported)." "$payload"
else
	json_output "ok" "Validation applied: ${summary}.${note}" "$payload"
fi
exit 0
