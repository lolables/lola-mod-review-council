#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-apply-triage.sh <session_dir>
# Applies the subsystem triage matrix a fresh-context subagent produced in
# ${session_dir}/triage.raw.md to the per-subsystem councils in
# session-manifest.json, subject to the invariants below.
#
# Triage decides WHERE a persona looks, never WHETHER its lens runs. That is
# the whole safety argument for letting a cheap model narrow anything here: a
# wrong exclusion costs one lens's view of one subsystem, and that lens still
# reviews every other subsystem. It is an invariant enforced below, not a
# property anyone assumes.
#
# The agent emits EXCLUSIONS ONLY. Every cell it does not name is dispatched,
# so a truncated, empty or malformed reply can only ever mean more review —
# fail-open is a property of the message shape rather than of remembering to
# handle each failure. The model contributes the matrix; this script owns every
# structural decision, the same split decompose.md has with the scripts that
# consume subsystems.json.
#
# Deep mode only. In standard mode there is one implicit subsystem, where
# excluding a persona is not "look elsewhere" but "do not run" — a judgement no
# cheap model should make (see references/model-guidance.md).
#
# This script makes no forge calls, so it does not require GNU timeout.

session_dir="${1:-}"
if [[ -z "$session_dir" ]] || [[ ! -d "$session_dir" ]]; then
	json_output "nothing_to_do" "Session directory does not exist."
	exit 0
fi

manifest="$session_dir/session-manifest.json"
subsystems_file="$session_dir/subsystems.json"
tracking_file="$session_dir/tracking.md"
raw_file="$session_dir/triage.raw.md"

[[ -f "$manifest" ]] || {
	json_output "nothing_to_do" "Session is missing session-manifest.json."
	exit 0
}
if [[ ! -f "$subsystems_file" ]] || ! jq -e 'length > 0' "$subsystems_file" >/dev/null 2>&1; then
	json_output "nothing_to_do" "No subsystems: triage applies to deep-mode runs only."
	exit 0
fi
triage_switch=$(rc_parse_kv "$tracking_file" "Subsystem triage")
if [[ "${triage_switch,,}" != "on" ]]; then
	json_output "nothing_to_do" "Subsystem triage is not enabled for this session."
	exit 0
fi
[[ -f "$raw_file" ]] || {
	json_output "nothing_to_do" "No triage output to apply."
	exit 0
}

# ============================================================================
# Extract and validate
# ============================================================================

# The first fenced ```json block in the agent's reply. Same extractor shape as
# rc-extract-verdict.sh, for the same reason: the reply is prose with a block
# in it, not a bare JSON file.
block=$(awk '
	/^```json[[:space:]]*$/ && !inb { inb=1; next }
	/^```[[:space:]]*$/ && inb { exit }
	inb { print }
' "$raw_file")

if [[ -z "${block//[[:space:]]/}" ]]; then
	json_output "triage_error" "Triage output contains no fenced json block. Councils are unchanged."
	exit 0
fi

# The structural check mirrors references/triage-schema.json, which is the
# published contract. It is a jq check rather than a call to a schema validator
# binary because the schema is three fields deep and a validator is not a
# prerequisite on every host — rc-extract-verdict.sh carries the full
# validator-or-degrade dance because verdict-schema.json needs it, and repeating
# that machinery for this would be more code than the rule it enforces.
#
# Drift between the two is what a hand-written check gets wrong, so the key sets
# are declared on one line each and test-rc-doc-guards.sh diffs them against the
# schema file — the same guard RC_TOP_KEYS carries against verdict-schema.json.
readonly RC_TRIAGE_TOP_KEYS='["exclusions"]'
readonly RC_TRIAGE_ITEM_KEYS='["subsystem","persona","reason"]'

# Refused whole, never in part: honouring the well-formed half of a malformed
# matrix means acting on a document the agent did not write.
valid=$(jq -n --argjson top "$RC_TRIAGE_TOP_KEYS" --argjson item "$RC_TRIAGE_ITEM_KEYS" \
	--slurpfile doc <(printf '%s' "$block") '
	($doc[0]? // null) as $d
	| if ($d | type) != "object" then false
	  elif (($d | keys) - $top | length) > 0 then false
	  elif ($d.exclusions | type) != "array" then false
	  elif ($d.exclusions | length) > 200 then false
	  else ($d.exclusions | all(
	      (type == "object")
	      and ((keys | sort) == ($item | sort))
	      and ((.subsystem | type) == "string") and (.subsystem | length) >= 1 and (.subsystem | length) <= 200
	      and ((.persona | type) == "string") and (.persona | test("^[a-z][a-z0-9-]*$")) and (.persona | length) <= 50
	      and ((.reason | type) == "string") and (.reason | length) >= 20 and (.reason | length) <= 500))
	  end' 2>/dev/null) || valid="false"

if [[ "$valid" != "true" ]]; then
	json_output "triage_error" "Triage output does not match triage-schema.json. Councils are unchanged."
	exit 0
fi

exclusions=$(jq -c '.exclusions' <<<"$block")
suffix=$(jq -r '.suffix // "code"' "$manifest")

# ============================================================================
# Resolve the matrix against the councils shape selection left behind
# ============================================================================
#
# Everything below is one jq program over three inputs — the manifest, the
# subsystem file lists, and the findings of the previous iteration. It is a
# single program rather than a bash loop because the invariants are set
# operations over the whole grid, and a grid assembled a row at a time in bash
# would need the same joins written twice.
findings_file="$session_dir/verdicts/findings.json"
findings_json='{"verified":[],"correctable":[]}'
[[ -f "$findings_file" ]] && findings_json=$(jq -c '{verified: (.verified // []), correctable: (.correctable // [])}' \
	"$findings_file" 2>/dev/null || echo '{"verified":[],"correctable":[]}')

result=$(jq -n \
	--slurpfile man "$manifest" \
	--slurpfile subs "$subsystems_file" \
	--argjson excl "$exclusions" \
	--argjson findings "$findings_json" \
	--arg suffix "$suffix" '
	($man[0]) as $m
	| ($m.subsystems // []) as $subsystems
	| ($m.agents // []) as $roster

	# Which agent name a persona means in this session. A persona outside the
	# discovered roster names no reviewer, and is dropped rather than recorded
	# as a skip: inventing a coverage gap is worse than ignoring a typo.
	| (def agent_of: "divisor-" + . + "-" + $suffix;

	# INVARIANT 5 — unknown names. An exclusion must name a subsystem this run
	# decomposed and a persona this host installed.
	# INVARIANT 3 — subtract only. A persona shape selection already took off
	# this subsystem is a no-op, not a second skip; the shape reason is the
	# accurate one and stays.
	   ([$excl[]
	     | . + {agent: (.persona | agent_of)}
	     | select(.subsystem as $s | ($subsystems | map(.name) | index($s)) != null)
	     | select(.agent as $a | ($roster | index($a)) != null)
	     | select(. as $e
	         | ($subsystems[] | select(.name == $e.subsystem) | .council | index($e.agent)) != null)]
	    | unique_by([.subsystem, .agent])) as $candidates

	# INVARIANT 4 — a reviewer with an open finding in a subsystem is restored
	# to it. On a re-review the agent that filed a finding has to be present to
	# judge the fix, and triage must not be able to remove the only reviewer
	# who knows about it. Correctable findings count as open too: they are
	# re-dispatched for correction, so their author is still owed the subsystem.
	# Stripped findings do not — a stripped finding is the fabrication the
	# pipeline exists to discard.
	   | (($subs[0] // []) | map({name, files: (.files // [])})) as $filemap
	   | ([($findings.verified + $findings.correctable)[]
	       | . as $f | $filemap[] | select(.files | index($f.file))
	       | {subsystem: .name, agent: $f.agent}]
	      | unique) as $pinned
	   | ([$candidates[] | select(. as $c
	       | ($pinned | index({subsystem: $c.subsystem, agent: $c.agent})) == null)]) as $after_pins
	   | ([$candidates[] | select(. as $c
	       | ($pinned | index({subsystem: $c.subsystem, agent: $c.agent})) != null)
	       | {rule: "open-finding", subsystem, persona,
	          detail: "this reviewer has an unresolved finding in this subsystem"}]) as $refused_pins

	# INVARIANT 1 — row coverage. A persona excluded from EVERY subsystem whose
	# council it is in has been removed from the review by the back door, one
	# subsystem at a time. All of its exclusions are dropped.
	   | ([$roster[] | . as $a
	       | {agent: $a,
	          present: ([$subsystems[] | select(.council | index($a))] | length),
	          cut: ([$after_pins[] | select(.agent == $a)] | length)}
	       | select(.present > 0 and .cut >= .present) | .agent]) as $row_violators
	   | ([$after_pins[] | select(.agent as $a | ($row_violators | index($a)) == null)]) as $after_rows
	   | ([$row_violators[] | {rule: "row-coverage", persona: (. | sub("^divisor-"; "") | sub("-[a-z]+$"; "")),
	       agent: ., detail: "excluded from every subsystem it reviews; a lens must review something"}]) as $refused_rows

	# INVARIANT 2 — column floor. A subsystem may not fall below two reviewers
	# through triage. Shape selection can already take one to two, and this
	# stops the two mechanisms compounding. Its exclusions are dropped
	# wholesale, so no ranking judgement is needed to choose which survive.
	   | ([$subsystems[] | . as $s
	       | {name: .name,
	          remaining: ((.council | length) - ([$after_rows[] | select(.subsystem == $s.name)] | length))}
	       | select(.remaining < 2) | .name]) as $floor_violators
	   | ([$after_rows[] | select(.subsystem as $n | ($floor_violators | index($n)) == null)]) as $applied
	   | ([$floor_violators[] | {rule: "column-floor", subsystem: .,
	       detail: "triage would leave fewer than two reviewers on this subsystem"}]) as $refused_floor

	# Rewrite each subsystem council, and recompute the two top-level fields
	# from the result so the manifest cannot contradict itself. `council` is the
	# union — an agent that reviews anywhere owes a verdict, which is what
	# rc-verify-evidence.sh diffs against — and `deselected` is the agents with
	# no coverage anywhere.
	   | ($subsystems | map(. as $s
	       | ([$applied[] | select(.subsystem == $s.name)]) as $cut
	       | .council = [.council[] | select(. as $a | ($cut | map(.agent) | index($a)) == null)]
	       | .deselected = ((.deselected // []) +
	           [$cut[] | {agent, persona, source: "triage", reason}] | sort_by(.agent))))
	     as $new_subsystems
	   | ($new_subsystems | map(.council[]) | unique) as $union
	   | {subsystems: $new_subsystems,
	      council: $union,
	      deselected: ([$new_subsystems[] | .deselected[]] | group_by(.agent) | map(.[0])
	                   | map(select(.agent as $a | ($union | index($a)) == null)) | sort_by(.agent)),
	      excluded: $applied,
	      refused: ($refused_pins + $refused_rows + $refused_floor)})
	')

applied_list=$(jq -c '.excluded' <<<"$result")
refused_list=$(jq -c '.refused' <<<"$result")
applied_count=$(jq -r '.excluded | length' <<<"$result")
refused_count=$(jq -r '.refused | length' <<<"$result")

# Names that reached none of the invariants because they matched nothing at
# all. Reported on stderr rather than in the artifact: a hallucinated subsystem
# name is a fault in the triage prompt, not a fact about this review's coverage.
while IFS= read -r bad; do
	[[ -n "$bad" ]] || continue
	echo "rc-apply-triage: ignoring exclusion for unknown subsystem or persona: ${bad}" >&2
done < <(jq -r --slurpfile man "$manifest" --slurpfile subs "$subsystems_file" --arg suffix "$suffix" '
	($man[0].agents // []) as $roster
	| (($subs[0] // []) | map(.name)) as $names
	| .[] | select((($names | index(.subsystem)) == null)
	    or (($roster | index("divisor-" + .persona + "-" + $suffix)) == null))
	| "\(.subsystem)/\(.persona)"' <<<"$exclusions" 2>/dev/null || true)

# ============================================================================
# Persist
# ============================================================================

# Written through a temp file and moved into place: this script is re-runnable
# (SKILL.md Step 2 resumes a session mid-run), and a redirect straight onto the
# file jq is reading truncates it before jq opens it, losing the grid with
# nothing left to rebuild it from.
manifest_tmp="${manifest}.tmp"
jq --argjson r "$result" --argjson applied "$applied_count" --argjson refused "$refused_count" \
	'. + {subsystems: $r.subsystems, council: $r.council, deselected: $r.deselected,
	      triage: {applied: ($applied > 0), excluded: $applied, refused: $refused,
	               refusals: $r.refused}}' \
	"$manifest" >"$manifest_tmp"
mv "$manifest_tmp" "$manifest"

if [[ -f "$tracking_file" ]]; then
	# Replaced rather than appended, which is what makes a re-run a no-op: awk
	# drops any previous block from its heading to the next `## ` heading or end
	# of file. The filter and the move are separate statements, not an
	# `awk ... && mv` list — in a list the awk failure would be exempt from
	# `set -e`, the move would be skipped, and the run would end with a stale
	# block in place and a second one beneath it.
	if grep -q '^## Phase: Subsystem Triage$' "$tracking_file"; then
		tracking_tmp="${tracking_file}.tmp"
		awk '
			/^## Phase: Subsystem Triage$/ { skip = 1; next }
			skip && /^## / { skip = 0 }
			!skip { print }
		' "$tracking_file" >"$tracking_tmp"
		mv "$tracking_tmp" "$tracking_file"
	fi
	dispatch_total=$(jq -r '[.subsystems[].council | length] | add // 0' "$manifest")
	{
		echo "## Phase: Subsystem Triage"
		echo ""
		if [[ "$applied_count" -gt 0 ]]; then
			echo "- Triage: applied"
		else
			echo "- Triage: not applied"
		fi
		echo "- Cells excluded: ${applied_count}"
		echo "- Refused: ${refused_count}"
		echo "- Dispatches after triage: ${dispatch_total}"
		# One line per refusal, because a refusal is the record of the council
		# declining to narrow as far as it was asked to — the half of this phase
		# that nothing else would show.
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			echo "$line"
		done < <(jq -r '.[] | "- Refused (\(.rule)): \(.subsystem // .persona // "?") — \(.detail)"' \
			<<<"$refused_list" 2>/dev/null || true)
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			echo "$line"
		done < <(jq -r '.[] | "- Skipped \(.persona) on \(.subsystem): \(.reason)"' \
			<<<"$applied_list" 2>/dev/null || true)
		echo ""
	} >>"$tracking_file"
fi

if [[ "$applied_count" -gt 0 ]]; then
	message="Triage narrowed the grid by ${applied_count} dispatch(es); ${refused_count} exclusion(s) refused."
else
	message="Triage applied nothing; ${refused_count} exclusion(s) refused. Every council stands."
fi

payload=$(jq -n --argjson applied "$applied_count" --argjson excluded "$applied_list" \
	--argjson refused "$refused_list" \
	'{applied: ($applied > 0), excluded: $excluded, refused: $refused}')
json_output "ok" "$message" "$payload"
exit 0
