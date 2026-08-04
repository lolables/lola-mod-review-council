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

# Gather agent JSON files. Allow-list by agent-name prefix rather than excluding
# known artifacts: `verdicts/` also accumulates orchestrator-written files
# (clusters.json from verify.md Step 3c, disposition.txt, verification.txt, ...),
# and a deny-list has to grow every time a phase writes a new one — a miss feeds
# a non-verdict file to jq and aborts the phase, which breaks the mid-run resume
# SKILL.md Step 2 advertises. Reviewer agents are discovered as
# `divisor-*-{code,spec}.md`, so their verdict files are exactly `divisor-*.json`
# (deep mode nests them one level under a subsystem directory; find still reaches
# them).
agent_files=()
while IFS= read -r -d '' f; do agent_files+=("$f"); done \
	< <(find "$vdir" -name 'divisor-*.json' -type f -print0 2>/dev/null || true)
[[ ${#agent_files[@]} -gt 0 ]] || {
	json_output "nothing_to_do" "No agent verdict JSON found."
	exit 0
}

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

# Verify each finding. Emit status + reason, keeping all fields.
resolve() { [[ "$review_root" == "." ]] && echo "$1" || echo "${review_root%/}/$1"; }

# Absolute, symlink-resolved review root, for the containment check below.
root_abs=$(cd "$review_root" 2>/dev/null && pwd -P) || {
	json_output "nothing_to_do" "Review root does not exist: $review_root"
	exit 0
}

# True when <path> resolves inside the review root. The `file` field is
# LLM-authored: without this, `../../etc/shadow` (or any absolute path reachable
# from the root) resolves, reads, and verifies, letting a reviewer launder
# content from outside the changeset as evidence.
#
# The leaf is resolved as well as the directory, because resolving only the
# directory leaves a symlink AT the leaf pointing wherever it likes and the
# evidence reader follows it. That is reachable on a materialised foreign-PR
# review, where the tree under the root is PR-author-controlled and the review
# root IS the PR head. Resolving the leaf costs no legitimate coverage: a
# symlink tracked inside the repository resolves back under root_abs and still
# verifies, and a dangling one never gets this far — the `-f` test above has
# already filed it as FILE_NOT_FOUND. Only a link that escapes the root changes
# outcome, and it becomes PATH_OUTSIDE_ROOT.
#
# The chain is walked a hop at a time rather than handed to `readlink -f`: the
# canonicalising flags are GNU extensions, Homebrew installs GNU readlink as
# `greadlink` and leaves BSD readlink on PATH, and the CI matrix runs macOS.
# Flagless `readlink` is portable, and each hop canonicalises its directory with
# the same `cd … && pwd -P` used for the review root above. Walking is required
# rather than resolving one hop: a single hop lands on an intermediate link and
# reports that name's containment, which passes an escaping chain whose first
# hop sits inside the root. The hop budget matches the kernel's own MAXSYMLINKS,
# so any chain the evidence reader could follow resolves here too, and a cycle
# — which the reader cannot follow either — reports as not contained.
path_in_root() { # path
	local dir base dir_abs tgt hops=0
	dir=$(dirname -- "$1")
	base=$(basename -- "$1")
	dir_abs=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
	while [[ -L "$dir_abs/$base" ]]; do
		hops=$((hops + 1))
		[[ $hops -le 40 ]] || return 1
		tgt=$(readlink -- "$dir_abs/$base") || return 1
		[[ "$tgt" == /* ]] || tgt="$dir_abs/$tgt"
		dir_abs=$(cd "$(dirname -- "$tgt")" 2>/dev/null && pwd -P) || return 1
		base=$(basename -- "$tgt")
	done
	[[ "$dir_abs/$base" == "$root_abs" || "$dir_abs/$base" == "$root_abs"/* ]]
}

# Print the 1-based start line of every contiguous occurrence of <evidence> in
# <file>, one per line; print nothing when it does not occur.
#
# This replaces `grep -F`, whose POSIX semantics treat each newline in the
# pattern as a PATTERN SEPARATOR rather than a literal character. A multi-line
# quote was therefore searched as N independent literals and matched if any one
# of them did, which broke verification in both directions: fabricated blocks
# ending on a line that exists anywhere in the file were accepted, and accurate
# citations were rejected because the reported line came from whichever short
# literal happened to appear first in the file.
#
# Evidence crosses into awk through the environment, not `-v`: awk applies
# escape processing to `-v` assignments, so a literal backslash in the evidence
# would be silently rewritten before the comparison.
evidence_lines() { # file evidence
	RC_EV="$2" awk '
		BEGIN { ev = ENVIRON["RC_EV"]; k = split(ev, evl, "\n") }
		{ buf[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) {
				# evl[1] is a substring of the start line in every case: for
				# single-line evidence it is the whole pattern, and for
				# multi-line evidence it is the (possibly partial) first line.
				# Cheap reject before building a window.
				if (index(buf[i], evl[1]) == 0) continue
				if (k == 1) { print i; continue }
				# Evidence spanning k lines touches at most k file lines,
				# wherever within line i it begins. Trailing "\n" on each line
				# lets evidence that ends on a line boundary match at EOF.
				win = ""
				for (j = 0; j < k && i + j <= NR; j++) win = win buf[i + j] "\n"
				p = index(win, ev)
				# Require the match to begin within line i so each occurrence is
				# reported once, at its true start line.
				if (p > 0 && p <= length(buf[i]) + 1) print i
			}
		}
	' "$1"
}

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
	fpath=$(resolve "$f")
	if [[ ! -f "$fpath" ]]; then
		stripped=$(echo "$stripped" | jq --argjson o "$obj" '. + [$o + {status:"stripped", reason:"FILE_NOT_FOUND"}]')
		continue
	fi
	# shellcheck disable=SC2310 # path_in_root is a predicate; suspending set -e
	# inside it is the intended contract (it reports containment as 0/1, and a
	# path whose directory cannot be entered is "not contained", not fatal).
	if ! path_in_root "$fpath"; then
		stripped=$(echo "$stripped" | jq --argjson o "$obj" '. + [$o + {status:"stripped", reason:"PATH_OUTSIDE_ROOT"}]')
		continue
	fi
	# An evidence-free finding is unverifiable by construction, and the empty
	# string is a substring of every file — it must never reach the matcher.
	if [[ -z "$ev" || "$ev" == "null" ]]; then
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"EVIDENCE_EMPTY"}]')
		continue
	fi
	# Capture the status so a matcher failure (unreadable file, awk error) is
	# surfaced loudly rather than silently folded into EVIDENCE_NOT_FOUND.
	astatus=0
	# shellcheck disable=SC2310 # suspending set -e here is the point: the
	# status is captured into $astatus and handled explicitly below, which is
	# what keeps a scan failure distinguishable from a clean miss.
	occurrences=$(evidence_lines "$fpath" "$ev") || astatus=$?
	if [[ $astatus -ne 0 ]]; then
		echo "rc-verify-evidence: evidence scan failed (exit $astatus) on $fpath for finding $i" >&2
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"EVIDENCE_SCAN_ERROR"}]')
		continue
	fi
	if [[ -z "$occurrences" ]]; then
		correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"EVIDENCE_NOT_FOUND"}]')
		continue
	fi
	# Only a value bash arithmetic accepts may reach it. Flooring above fixes
	# 12.0, but two shapes still get through: a magnitude large enough to be
	# rendered in exponent form ("1e+300"), and a leading-zero run ("08"), which
	# bash reads as octal. Bash reports neither as a failed command — it tears
	# down this loop, so the finding AND every finding after it disappear from
	# all three buckets while findings.json is still written and total_findings
	# still claims them.
	#
	# The pattern is therefore keyed to the schema's own bounds: the leading
	# [1-9] is `minimum: 1`, which rejects the leading zero along with 0 itself,
	# and the digit count is that of `maximum: 10000000` — a digit-width cap
	# rather than the exact bound, but far below the magnitude at which jq
	# switches to exponent form. Bounding rather than "digits" is also what makes
	# `10#` unnecessary here: an octal-looking token cannot reach the arithmetic
	# to be reinterpreted. A value outside the bounds is read as an uncited line
	# instead — the evidence match is still required, the finding is simply not
	# line-anchored.
	if [[ "$line" =~ ^[1-9][0-9]{0,7}$ ]]; then
		lo=$((line - 5))
		hi=$((line + 5))
		[[ $lo -lt 1 ]] && lo=1
		# Accept when ANY occurrence lands in the window, not just the first:
		# identical blocks legitimately repeat across sibling test functions and
		# sibling handlers, and a citation of the second or third is accurate.
		near=0
		while IFS= read -r occ; do
			[[ -n "$occ" ]] || continue
			if [[ $occ -ge $lo && $occ -le $hi ]]; then
				near=1
				break
			fi
		done <<<"$occurrences"
		if [[ $near -eq 0 ]]; then
			correctable=$(echo "$correctable" | jq --argjson o "$obj" '. + [$o + {status:"correctable", reason:"LINE_MISMATCH"}]')
			continue
		fi
	fi
	verified=$(echo "$verified" | jq --argjson o "$obj" '. + [$o + {status:"verified"}]')
done

# Dedup verified: same file, line within +-5 (or both null), same evidence.
# On merge, keep the MOST SEVERE of the duplicates so a HIGH citing the same
# line as a LOW is never silently downgraded (the survivor's other fields stay
# from the first occurrence). Making the kept severity the max also makes the
# result independent of agent/finding ordering.
#
# The loser is folded into the survivor's provenance.consolidated_from in the
# shape rc-consolidate.sh writes, so the report's "Also flagged by" list covers
# both paths. Two reviewers converging on one line is the same event whether
# they quoted the same bytes (here) or were clustered as semantically equal
# (there); crediting it in one path and dropping it in the other loses a
# reviewer's angle with nothing recording that it was ever filed.
#
# Only a duplicate from a DIFFERENT agent is credited. The dedup key is file +
# line + evidence and deliberately excludes the agent, so one reviewer listing
# the same finding twice also merges here — and folding that would publish
# "Also flagged by" naming the survivor's own author.
before=$(echo "$verified" | jq 'length')
verified=$(echo "$verified" | jq '
	def sevrank(s): {"CRITICAL":4,"HIGH":3,"MEDIUM":2,"LOW":1}[s] // 0;
	reduce .[] as $x ([];
		( [ range(0; length) as $j | select(.[$j].file == $x.file and .[$j].evidence == $x.evidence and
			((.[$j].line == null and $x.line == null) or
			 (.[$j].line != null and $x.line != null and
			  ((.[$j].line - $x.line | if . < 0 then -. else . end) <= 5)))) | $j ] | first) as $idx
		| if $idx == null then . + [$x]
		  else
			( if $x.agent != .[$idx].agent
			  then .[$idx].provenance.consolidated_from =
				((.[$idx].provenance.consolidated_from // [])
				 + [{agent: $x.agent, severity: $x.severity,
				     angle: $x.description, recommendation: $x.recommendation}])
			  else . end )
			| ( if sevrank($x.severity) > sevrank(.[$idx].severity)
			    then .[$idx].severity = $x.severity
			    else . end )
		  end)
')
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
jq -n \
	--slurpfile verified "$argdir/verified.json" \
	--slurpfile correctable "$argdir/correctable.json" \
	--slurpfile stripped "$argdir/stripped.json" \
	--argjson total "$n" \
	--argjson dedup "$dedup" \
	--slurpfile vmap "$vdir/verdicts-map.json" \
	'{verified:$verified[0], correctable:$correctable[0], stripped:$stripped[0],
	  total_findings:$total, duplicates_consolidated:$dedup, verdicts:$vmap[0]}' \
	>"$vdir/findings.json"

vc=$(echo "$verified" | jq 'length')
cc=$(echo "$correctable" | jq 'length')
sc=$(echo "$stripped" | jq 'length')
payload=$(jq -n --argjson v "$vc" --argjson c "$cc" --argjson s "$sc" '{verified:$v, correctable:$c, stripped:$s}')
json_output "ok" "Evidence verification complete. $vc verified, $cc correctable, $sc stripped." \
	"$payload"
exit 0
