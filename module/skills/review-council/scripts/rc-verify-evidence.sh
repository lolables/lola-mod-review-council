#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-verify-evidence.sh <session_dir> [review_root]
# Consumes verdicts/<agent>.json (produced by rc-extract-verdict.sh), verifies
# each finding mechanically, deduplicates, and writes the canonical findings.json.
# Verdict is copied verbatim from each agent's JSON — never re-derived.

session_dir="${1:-}"
review_root="${2:-${REVIEW_ROOT:-.}}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
}
vdir="$session_dir/verdicts"
[[ -d "$vdir" ]] || {
	json_output "nothing_to_do" "No verdicts directory found."
	exit 0
}

# Gather agent JSON files. Allow-list by agent-name prefix, and kept that way
# even now that orchestrator-written state lives in verdicts/_meta/ rather than
# beside the verdicts: the two defences answer different questions. The _meta
# split stops a phase artifact being written where this glob looks; the
# allow-list stops anything that lands here anyway from being parsed as a
# verdict. RC-4 was clusters.json fed to jq as an agent verdict, which aborted
# the phase and broke the mid-run resume SKILL.md Step 2 advertises — a
# deny-list would have to grow every time a phase writes a new artifact, and one
# miss is all it takes. Reviewer agents are discovered as
# `divisor-*-{code,spec}.md`, so their verdict files are exactly `divisor-*.json`
# (deep mode nests them one level under a subsystem directory; find still reaches
# them).
#
# Sorted, because the order these are read in decides the content of the review.
# Dedup keeps the first occurrence of a duplicated finding and credits the later
# one to `provenance.consolidated_from`, so ingestion order picks which reviewer
# the report quotes and which it lists under "Also flagged by". `find` reports
# directory order, which is the filesystem's business and nobody else's:
# creation order on XFS, hash order on ext4, neither on APFS. The same session
# therefore produced different reports on different hosts — the CI matrix caught
# it as one suite passing on one leg and failing on the other two, and a review
# is not reproducible if re-running it on another machine can change who gets
# credited. LC_ALL=C so the collation is the byte order everywhere rather than
# the caller's locale.
agent_files=()
while IFS= read -r -d '' f; do agent_files+=("$f"); done \
	< <(find "$vdir" -name 'divisor-*.json' -type f -print0 2>/dev/null | LC_ALL=C sort -z || true)
[[ ${#agent_files[@]} -gt 0 ]] || {
	json_output "nothing_to_do" "No agent verdict JSON found."
	exit 0
}

# Agents the session manifest says were dispatched, but which produced no
# verdict file. Without this they are invisible: a reviewer that returned
# nothing and a reviewer that was never in the council both show up as simply
# absent from the glob above, and only one of them is a hole in the review.
#
# Reported, never fatal — a silent agent is a coverage gap for the report to
# disclose, not a reason to discard the verdicts that did arrive. A session with
# no manifest (hand-built, or predating it) claims nothing rather than accusing
# every agent at once.
#
# The diff is against `council`, not `agents`. Since contextual persona
# selection (rc-select-council.sh) the two can differ: `agents` is who was
# DISCOVERED and `council` is who was DISPATCHED, and a persona the selector
# deliberately skipped owes no verdict. Counting it here would report a
# deliberate, disclosed skip as a dropped verdict — the one confusion the
# three-state model exists to prevent, and the direction that turns a cheaper
# review into an apparent failure. `// .agents` covers a manifest written before
# the key existed, where the two sets were the same by definition.
#
# A manifest that parses but holds no list of names claims nothing, exactly as
# rc-extract-verdict.sh treats it: a string `council` or a top-level array used
# to abort this script one stage after extraction had handled the same file.
missing_json='[]'
manifest="$session_dir/session-manifest.json"
if [[ -f "$manifest" ]]; then
	found_json=$(printf '%s\n' "${agent_files[@]}" |
		sed 's|.*/||; s|\.json$||' | sort -u | jq -R . | jq -s .)
	missing_json=$(jq -n --slurpfile m "$manifest" --argjson found "$found_json" \
		'if ($m[0] | type) != "object" then [] else
		 ($m[0].council // $m[0].agents // []) as $c
		 | if ($c | type) == "array" and ($c | all(type == "string"))
		   then [ $c[] | select(. as $a | ($found | index($a)) | not) ] else [] end end')
fi

# Merge all findings into one array, tagging each with its agent and verdict.
all=$(jq -s '
	map(
		.agent as $a | .verdict as $v |
		(.findings // []) | map(. + {agent:$a, verdict:$v})
	) | add // []
' "${agent_files[@]}")

# Per-agent verdict map, for the report/comment table. In deep mode the same
# agent runs once per subsystem; aggregate REQUEST-CHANGES-wins so a single
# subsystem flagging an issue can't be silently overridden by another
# subsystem's APPROVE (flat mode: one instance per agent, so this is a no-op).
jq -s '
	group_by(.agent) | map({key: .[0].agent,
		value: (if any(.[]; .verdict | test("REQUEST CHANGES")) then "REQUEST CHANGES" else .[0].verdict end)})
	| from_entries
' "${agent_files[@]}" >"$vdir/verdicts-map.json"

# Absolute, symlink-resolved review root, for the containment check below.
root_abs=$(cd "$review_root" 2>/dev/null && pwd -P) || {
	json_output "nothing_to_do" "Review root does not exist: $review_root"
	exit 0
}
# shellcheck source=module/skills/review-council/scripts/lib/evidence.sh
source "$(dirname "$0")/lib/evidence.sh"

# Verify each finding. Emit status + reason, keeping all fields.

n=$(echo "$all" | jq 'length')
verified='[]'
correctable='[]'
stripped='[]'
for ((i = 0; i < n; i++)); do
	f=$(echo "$all" | jq -r ".[$i].file")
	# Floor the line rather than trusting the schema's type keyword. JSON Schema
	# draft-07 defines `integer` BY VALUE, so an LLM emitting 12.0 satisfies it
	# and the value arrives here as the literal "12.0" — which bash arithmetic
	# rejects. verdict-schema.json now also bounds the value, but that only
	# helps on hosts carrying a real validator: rc-extract-verdict.sh degrades to
	# a jq check that does test integrality but not magnitude, so nothing
	# upstream bounds the value on every other host. Flooring keeps 12.0 usable
	# as 12 instead of discarding an otherwise accurate citation.
	line=$(echo "$all" | jq -r ".[$i].line | if type == \"number\" then floor else . end // \"\"")
	ev=$(echo "$all" | jq -r ".[$i].evidence")
	obj=$(echo "$all" | jq -c ".[$i]")
	status=$(rc_evidence_status "$f" "$line" "$ev")
	case "$status" in
	verified)
		verified=$(echo "$verified" | jq --argjson o "$obj" '. + [$o + {status:"verified"}]')
		;;
	FILE_NOT_FOUND | PATH_OUTSIDE_ROOT)
		stripped=$(echo "$stripped" | jq --argjson o "$obj" --arg r "$status" '. + [$o + {status:"stripped", reason:$r}]')
		;;
	*)
		correctable=$(echo "$correctable" | jq --argjson o "$obj" --arg r "$status" '. + [$o + {status:"correctable", reason:$r}]')
		;;
	esac
done

# Dedup verified findings. The rules — the +-5 line window, max-severity on
# merge, and crediting a cross-agent duplicate in provenance.consolidated_from —
# live in jq/dedup-findings.jq, which documents each and is exercised directly
# by test-rc-jq-programs.sh. It sits in a file rather than inline because this
# reducer has already produced one silent-data-loss bug (RC-20) that no test
# could reach without first building a whole session.
before=$(echo "$verified" | jq 'length')
verified=$(echo "$verified" | jq -f "$(dirname "$0")/jq/dedup-findings.jq")
after=$(echo "$verified" | jq 'length')
dedup=$((before - after))

# Add provenance stub to every finding (calibration/dedup/validator fill later).
addprov='map(. + {provenance: (.provenance // {})})'
verified=$(echo "$verified" | jq "$addprov")
correctable=$(echo "$correctable" | jq "$addprov")
stripped=$(echo "$stripped" | jq "$addprov")

# The three finding arrays reach jq through files rather than argv. Linux caps
# a SINGLE argv entry at MAX_ARG_STRLEN (131071 bytes) regardless of the much
# larger ARG_MAX total, so `--argjson verified "$verified"` is bounded by the
# size of one review's findings: at 84 findings the array crossed the cap and
# the phase died with "Argument list too long" before findings.json was
# written. The count arguments stay on the command line — they cannot grow.
argdir=$(mktemp -d)
trap 'rm -rf "$argdir"' EXIT
printf '%s' "$verified" >"$argdir/verified.json"
printf '%s' "$correctable" >"$argdir/correctable.json"
printf '%s' "$stripped" >"$argdir/stripped.json"
# Every finding gets an ID here, once, numbered across all three arrays so no
# two share one. The validation gate (verify.md Step 4) keys its outcomes on it:
# before IDs, outcomes were matched to findings by position, and a validator
# that transposed two answers had them applied to the wrong findings silently.
jq -n \
	--slurpfile verified "$argdir/verified.json" \
	--slurpfile correctable "$argdir/correctable.json" \
	--slurpfile stripped "$argdir/stripped.json" \
	--argjson total "$n" \
	--argjson dedup "$dedup" \
	--argjson missing "$missing_json" \
	--slurpfile vmap "$vdir/verdicts-map.json" \
	'def ids($from): to_entries | map(.value + {id: "F\(.key + $from + 1)"});
	 ($verified[0] | length) as $nv | ($correctable[0] | length) as $nc |
	 {verified:($verified[0] | ids(0)), correctable:($correctable[0] | ids($nv)),
	  stripped:($stripped[0] | ids($nv + $nc)),
	  total_findings:$total, duplicates_consolidated:$dedup, verdicts:$vmap[0],
	  missing_verdicts:$missing}' \
	>"$vdir/findings.json"
# Ids restart at F1 on every run, so a validator or correction-round reply
# saved against the previous findings.json would apply to this run's unrelated
# findings.
rm -f "$vdir/_meta/validation.json" "$vdir/_meta/corrections.json"

vc=$(echo "$verified" | jq 'length')
cc=$(echo "$correctable" | jq 'length')
sc=$(echo "$stripped" | jq 'length')
payload=$(jq -n --argjson v "$vc" --argjson c "$cc" --argjson s "$sc" \
	--argjson m "$missing_json" \
	'{verified:$v, correctable:$c, stripped:$s, missing_verdicts:$m}')
json_output "ok" "Evidence verification complete. $vc verified, $cc correctable, $sc stripped." \
	"$payload"
exit 0
