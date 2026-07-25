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
[[ -n "$session_dir" && -d "$session_dir" ]] || { json_output "nothing_to_do" "Session directory does not exist."; exit 0; }
vdir="$session_dir/verdicts"
[[ -d "$vdir" ]] || { json_output "nothing_to_do" "No verdicts directory found."; exit 0; }

# Gather agent JSON files.
agent_files=()
while IFS= read -r -d '' f; do agent_files+=("$f"); done \
	< <(find "$vdir" -name '*.json' ! -name 'findings.json' ! -name 'evidence-check.json' ! -name 'verdicts-map.json' -type f -print0 2>/dev/null || true)
[[ ${#agent_files[@]} -gt 0 ]] || { json_output "nothing_to_do" "No agent verdict JSON found."; exit 0; }

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
' "${agent_files[@]}" > "$vdir/verdicts-map.json"

# Verify each finding. Emit status + reason, keeping all fields.
resolve() { [[ "$review_root" == "." ]] && echo "$1" || echo "${review_root%/}/$1"; }

n=$(echo "$all" | jq 'length')
verified='[]'; correctable='[]'; stripped='[]'
for ((i=0; i<n; i++)); do
	f=$(echo "$all" | jq -r ".[$i].file")
	line=$(echo "$all" | jq -r ".[$i].line // \"\"")
	ev=$(echo "$all" | jq -r ".[$i].evidence")
	obj=$(echo "$all" | jq -c ".[$i]")
	fpath=$(resolve "$f")
	if [[ ! -f "$fpath" ]]; then
		stripped=$(echo "$stripped" | jq --argjson o "$obj" '. + [$o + {status:"stripped", reason:"FILE_NOT_FOUND"}]')
		continue
	fi
	# `--` ends option parsing: evidence quoted from a Markdown bullet, a diff
	# line, or a CLI flag begins with `-` and would otherwise be read as a grep
	# option. Capture the status so a grep tooling error (exit 2) is surfaced
	# loudly rather than silently folded into EVIDENCE_NOT_FOUND (exit 1).
	gstatus=0
	grep -qF -- "$ev" "$fpath" || gstatus=$?
	if [[ $gstatus -eq 2 ]]; then
		echo "rc-verify-evidence: grep failed (exit 2) on $fpath for finding $i" >&2
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"GREP_ERROR"}]')
		continue
	elif [[ $gstatus -ne 0 ]]; then
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"EVIDENCE_NOT_FOUND"}]')
		continue
	fi
	if [[ -n "$line" && "$line" != "null" ]]; then
		actual=$(grep -nF -- "$ev" "$fpath" | head -1 | cut -d: -f1)
		if [[ -n "$actual" ]]; then
			lo=$((line-5)); hi=$((line+5)); [[ $lo -lt 1 ]] && lo=1
			if [[ $actual -lt $lo || $actual -gt $hi ]]; then
				correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"LINE_MISMATCH"}]')
				continue
			fi
		fi
	fi
	verified=$(echo "$verified" | jq --argjson o "$obj" '. + [$o + {status:"verified"}]')
done

# Dedup verified: same file, line within +-5 (or both null), same evidence.
# On merge, keep the MOST SEVERE of the duplicates so a HIGH citing the same
# line as a LOW is never silently downgraded (the survivor's other fields stay
# from the first occurrence). Making the kept severity the max also makes the
# result independent of agent/finding ordering.
before=$(echo "$verified" | jq 'length')
verified=$(echo "$verified" | jq '
	def sevrank(s): {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1}[s] // 0;
	reduce .[] as $x ([];
		( [ range(0; length) as $j | select(.[$j].file == $x.file and .[$j].evidence == $x.evidence and
			((.[$j].line == null and $x.line == null) or
			 (.[$j].line != null and $x.line != null and
			  ((.[$j].line - $x.line | if . < 0 then -. else . end) <= 5)))) | $j ] | first) as $idx
		| if $idx == null then . + [$x]
		  elif sevrank($x.severity) > sevrank(.[$idx].severity)
		  then .[$idx].severity = $x.severity
		  else . end)
')
after=$(echo "$verified" | jq 'length')
dedup=$((before - after))

# Add provenance stub to every finding (calibration/dedup/validator fill later).
addprov='map(. + {provenance: (.provenance // {})})'
verified=$(echo "$verified" | jq "$addprov")
correctable=$(echo "$correctable" | jq "$addprov")
stripped=$(echo "$stripped" | jq "$addprov")

jq -n \
	--argjson verified "$verified" \
	--argjson correctable "$correctable" \
	--argjson stripped "$stripped" \
	--argjson total "$n" \
	--argjson dedup "$dedup" \
	--slurpfile vmap "$vdir/verdicts-map.json" \
	'{verified:$verified, correctable:$correctable, stripped:$stripped,
	  total_findings:$total, duplicates_consolidated:$dedup, verdicts:$vmap[0]}' \
	> "$vdir/findings.json"

vc=$(echo "$verified" | jq 'length'); cc=$(echo "$correctable" | jq 'length'); sc=$(echo "$stripped" | jq 'length')
json_output "ok" "Evidence verification complete. $vc verified, $cc correctable, $sc stripped." \
	"$(jq -n --argjson v "$vc" --argjson c "$cc" --argjson s "$sc" '{verified:$v, correctable:$c, stripped:$s}')"
exit 0
