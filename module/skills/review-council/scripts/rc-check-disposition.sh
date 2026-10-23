#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-check-disposition.sh <session_dir> [--snapshot]
# Checks the Disposition phase's edits to verdicts/findings.json by script.
#
# The Disposition subagent reads PR conversation the PR author controls and
# edits findings.json directly; the council verdict depends only on the
# severities left in `verified`. Its limits were prose, so one injected reply
# that got a HIGH moved to `stripped` flipped REQUEST CHANGES to APPROVE.
#
# --snapshot, run before the subagent is dispatched, copies findings.json to
# verdicts/_meta/findings.pre-disposition.json and verdicts/verdicts-map.json
# to verdicts/_meta/verdicts-map.pre-disposition.json. It refuses to overwrite
# the first: a snapshot taken after the edits would bless them.
#
# Without it, run after the subagent returns and the orchestrator's Step 4
# moves, the check diffs the snapshot against findings.json under the rules in
# jq/check-disposition.jq. All or nothing: on any violation the snapshot is
# restored over findings.json, so every finding stays as verification left it,
# and the status names every violation. On success it derives `.verdicts` again
# from the findings Disposition left and the verdicts the reviewers filed
# (jq/recompute-verdicts.jq over the snapshot's copy of verdicts-map.json, the
# input rc-recompute-verdicts.sh uses), so a resolved reply upgrades its agent
# and an edit to `.verdicts` is overwritten, not kept, even one made before the
# snapshot. The copy is read, not verdicts-map.json itself, because the
# subagent can write beside findings.json.
# Disposition can neither add a finding nor change one's agent or severity, so
# after Verification's recompute this gives the map it would. It then writes
# verdicts/_meta/disposition-check.json with the hash of the findings.json it
# accepted; the render gate (rc_disposition_gate, rc-lib.sh) requires that file
# and that hash. Re-running on an unchanged state gives the same result.
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
usage="Usage: rc-check-disposition.sh <session_dir> [--snapshot]"
take_snapshot=false
shift
while (($# > 0)); do
	case "$1" in
	--snapshot)
		if $take_snapshot; then
			json_output "validation_error" "Repeated argument: --snapshot. ${usage}"
			exit 0
		fi
		take_snapshot=true
		shift
		;;
	*)
		json_output "validation_error" "Unknown argument: ${1}. ${usage}"
		exit 0
		;;
	esac
done

vdir="$session_dir/verdicts"
findings="$vdir/findings.json"
snapshot="$vdir/_meta/findings.pre-disposition.json"
check_file="$vdir/_meta/disposition-check.json"
rules="$(dirname "$0")/jq/check-disposition.jq"
recompute="$(dirname "$0")/jq/recompute-verdicts.jq"
declared_file="$vdir/_meta/verdicts-map.pre-disposition.json"

if $take_snapshot; then
	if [[ -e "$snapshot" || -L "$snapshot" ]]; then
		json_output "validation_error" \
			"A Disposition snapshot already exists (verdicts/_meta/findings.pre-disposition.json); refusing to replace it, since a snapshot taken after Disposition's edits would accept them. To run Disposition again, start over from Verification (rc-verify-evidence.sh clears it)."
		exit 0
	fi
	[[ -f "$findings" ]] || {
		json_output "nothing_to_do" "No findings.json found; Disposition has nothing to act on."
		exit 0
	}
	# The check ties every finding to its snapshot by id, so findings it could
	# not tie are refused here, before the subagent has edited anything. The
	# rules file holds the one definition of that (snapshot_ok).
	if ! jq -e --arg mode snapshot --argjson pre null -f "$rules" "$findings" >/dev/null 2>&1; then
		json_output "validation_error" \
			"findings.json is not a findings document with a unique id on every finding, so Disposition's edits could not be checked. Stop and report; no snapshot was taken."
		exit 0
	fi
	mkdir -p "$vdir/_meta"
	# Copied first, so a findings snapshot never sits beside an older map. A
	# map that is not there is not copied, and the check refuses for it.
	rm -f "$declared_file"
	if [[ -f "$vdir/verdicts-map.json" ]]; then
		cp "$vdir/verdicts-map.json" "$declared_file"
	fi
	cp "$findings" "$snapshot"
	json_output "ok" "Snapshot taken. Dispatch the Disposition subagent; after it returns and the Step 4 moves are made, run rc-check-disposition.sh ${session_dir}."
	exit 0
fi

# A check file describes one accepted findings.json. Removed before anything
# else, so no exit below leaves an earlier acceptance for the render gate.
rm -f "$check_file"

if [[ ! -f "$snapshot" ]] || ! jq -e 'type == "object"' "$snapshot" >/dev/null 2>&1; then
	json_output "validation_error" \
		"No readable Disposition snapshot, so findings.json (left unchanged) may already hold Disposition edits nothing has checked. Do not snapshot it now: re-run Verification (rc-verify-evidence.sh) to rebuild findings.json from the reviewer verdicts, then run Step 4.5 in order, rc-check-disposition.sh --snapshot before dispatching Disposition, then this check."
	exit 0
fi

work=$(mktemp -d)
restore=""
staged=""
trap 'rm -rf "$work"; [[ -z "$restore" ]] || rm -f "$restore"; [[ -z "$staged" ]] || rm -f "$staged"' EXIT
if [[ -L "$findings" ]]; then
	violations='["findings.json was replaced by a symlink"]'
elif [[ ! -f "$findings" ]]; then
	violations='["findings.json is missing"]'
else
	# Read once. The rules and the hash below both use this copy, so the hash
	# recorded is of the bytes the rules checked, never of a later re-read.
	checked="$work/findings.json"
	cp "$findings" "$checked"
	if ! jq -se 'length == 1' "$checked" >/dev/null 2>&1; then
		violations='["findings.json is not valid JSON (one document)"]'
	else
		jq --arg mode check --slurpfile pre "$snapshot" -f "$rules" "$checked" >"$work/result.json"
		violations=$(jq -c '.violations' "$work/result.json")
	fi
fi

if [[ "$violations" != "[]" ]]; then
	# Copied to a fresh file beside the target and renamed over it: a rename
	# replaces a symlink rather than writing through it, and mktemp never reuses
	# a name something could have planted. -p keeps the snapshot's mode rather
	# than mktemp's 0600.
	restore=$(mktemp "$vdir/.findings.restore.XXXXXX")
	cp -p "$snapshot" "$restore"
	mv -f "$restore" "$findings"
	restore=""
	listing=$(jq -r 'join("; ")' <<<"$violations")
	payload=$(jq -n --argjson v "$violations" '{violations: $v}')
	json_output "validation_error" \
		"Disposition broke its rules, so none of its edits were kept: findings.json is restored to the pre-Disposition snapshot and every finding stays as verification left it. Violations: ${listing}. Record them in disposition.txt, then run rc-check-disposition.sh ${session_dir} again (it accepts the restored file) before rendering." \
		"$payload"
	exit 0
fi

underivable="findings.json is unchanged and nothing is recorded for the render gate. Re-run Verification (rc-verify-evidence.sh, which writes the map), then Step 4.5 in order."
if [[ ! -f "$declared_file" ]] || ! jq -se 'length == 1' "$declared_file" >/dev/null 2>&1; then
	json_output "validation_error" \
		"Disposition's edits are within its rules, but the per-agent verdicts cannot be derived: there was no readable verdicts/verdicts-map.json (the verdicts the reviewers filed) when the snapshot was taken. ${underivable}"
	exit 0
fi
declared=$(jq -c . "$declared_file")
jq --argjson declared "$declared" -f "$recompute" "$checked" >"$work/recompute.json"
problem=$(jq -r '.problem // empty' "$work/recompute.json")
if [[ -n "$problem" ]]; then
	json_output "validation_error" \
		"Disposition's edits are within its rules, but the per-agent verdicts cannot be derived (${problem}). ${underivable}"
	exit 0
fi
# The accepted bytes: the checked copy, or that copy with its verdicts derived.
accepted="$checked"
if jq -e '.changes | length > 0' "$work/recompute.json" >/dev/null; then
	accepted="$work/accepted.json"
	jq '.doc' "$work/recompute.json" >"$accepted"
fi
digest=$(rc_sha256 "$accepted")
if [[ -z "$digest" ]]; then
	json_output "skip" "Neither sha256sum nor shasum is installed, so the checked findings.json cannot be recorded for the render gate. Install coreutils (brew install coreutils | apt-get install coreutils | dnf install coreutils), then run again."
	exit 0
fi
# Upgrades are counted against the snapshot, so a re-run reports the same
# count; verdict_changes lists what this run changed in findings.json, each
# truncated as finding ids are, since a hand edit may have written it.
# Built before findings.json is replaced, so a failure here leaves it as it was.
# The snapshot's map may be missing or not an object (snapshot_ok does not
# require one), and is read as empty, as the recompute reads it.
payload=$(jq --slurpfile pre "$snapshot" --slurpfile acc "$accepted" '.counts + {verdicts_upgraded:
	((($pre[0].verdicts | objects) // {}) as $o | (($acc[0].verdicts | objects) // {}) as $n
	 | [$o | keys[] | select($o[.] == "REQUEST CHANGES" and $n[.] == "APPROVE")] | length)}' "$work/result.json")
payload=$(jq --slurpfile r "$work/recompute.json" '. + {verdict_changes: [$r[0].changes[]
	| {agent: (.agent | .[:64]), from: (.from | if type == "string" then .[:64] else . end), to, rule}]}' <<<"$payload")
if [[ "$accepted" != "$checked" ]]; then
	# Staged beside the target and renamed over it, as the restore above is.
	staged=$(mktemp "$vdir/.findings.XXXXXX")
	cp "$accepted" "$staged"
	mv -f "$staged" "$findings"
	staged=""
fi
jq --arg h "$digest" '{status: "ok"} + . + {findings_sha256: $h}' <<<"$payload" >"$work/check.json"
mv -f "$work/check.json" "$check_file"
summary=$(jq -r '"\(.resolved) resolved, \(.suppressed_low) suppressed-low, \(.kept) kept, \(.verdicts_upgraded) verdict(s) upgraded, \(.verdict_changes | length) verdict(s) changed by the recompute"' <<<"$payload")
json_output "ok" "Disposition's edits are within its rules: ${summary}." "$payload"
exit 0
