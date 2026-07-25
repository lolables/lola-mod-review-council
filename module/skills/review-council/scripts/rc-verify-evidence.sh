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
	if ! grep -qF "$ev" "$fpath"; then
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"EVIDENCE_NOT_FOUND"}]')
		continue
	fi
	if [[ -n "$line" && "$line" != "null" ]]; then
		actual=$(grep -nF "$ev" "$fpath" | head -1 | cut -d: -f1)
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
before=$(echo "$verified" | jq 'length')
verified=$(echo "$verified" | jq '
	reduce .[] as $x ([];
		if any(.[]; .file == $x.file and .evidence == $x.evidence and
			((.line == null and $x.line == null) or
			 (.line != null and $x.line != null and
			  ((.line - $x.line | if . < 0 then -. else . end) <= 5))))
		then . else . + [$x] end)
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
