#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-extract-verdict.sh <session_dir>
# For each verdicts/<agent>.raw.md (raw agent output), extract the fenced ```json
# block, validate it structurally, then enforce the one invariant the schema
# cannot express: a verdict of APPROVE may not be filed over a CRITICAL or HIGH
# finding. Writes verdicts/<agent>.json on success, and adds a verdict's
# optional `model` to that role's `reported` list in models.json. Emits a JSON
# summary naming the validation mode it ran (`schema_validation`), which is also
# kept, worst-of, in verdicts/_meta/schema-validation.txt.
# Invalid/missing/incoherent blocks are reported for one re-dispatch.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || {
	json_output "skip" "Session directory not found."
	exit 0
}
vdir="$session_dir/verdicts"
[[ -d "$vdir" ]] || {
	json_output "nothing_to_do" "No verdicts directory."
	exit 0
}

# Extract the first fenced ```json ... ``` block from a file to stdout. A
# leading UTF-8 byte-order mark is dropped first: it is an artifact of how the
# file was written, and left in place it hides a fence on line 1. LC_ALL=C so
# substr() counts the mark's three bytes rather than one character.
extract_block() { # file
	LC_ALL=C RC_BOM=$'\xef\xbb\xbf' awk '
		NR == 1 && index($0, ENVIRON["RC_BOM"]) == 1 { $0 = substr($0, length(ENVIRON["RC_BOM"]) + 1) }
		/^```json[[:space:]]*$/ && !inb { inb=1; next }
		/^```[[:space:]]*$/ && inb { exit }
		inb { print }
	' "$1"
}

SCHEMA="$(cd "$(dirname "$0")/../references" && pwd)/verdict-schema.json"
_warned_no_validator=0

# Key sets allowed by "additionalProperties": false in verdict-schema.json.
# The jq fallback below has no way to read the schema (its whole purpose is to
# work on hosts where the schema tooling is missing), so the lists are declared
# here and test-rc-extract-verdict.sh diffs these two lines against the schema
# — drift fails the suite instead of silently splitting the two validation
# paths apart. Keep each on one line: the test extracts them with sed.
readonly RC_TOP_KEYS='["agent","files_read","verdict","findings","model","context_check"]'
readonly RC_FINDING_KEYS='["severity","file","line","title","evidence","constraint","description","recommendation","impact"]'
# The keys of the optional top-level `context_check` object, all required
# inside it. Same one-line rule as above — the schema-drift test reads it.
readonly RC_CONTEXT_CHECK_KEYS='["file","line","evidence"]'
# The subsets of the two lists above that "required" in verdict-schema.json
# names: what the rejection message calls a missing key. `model` and
# `context_check` are the optional top-level keys; `line`, `title`,
# `constraint` and `impact` are the optional finding keys. Same one-line rule
# as above — the schema-drift test reads them.
readonly RC_REQUIRED_TOP_KEYS='["agent","files_read","verdict","findings"]'
readonly RC_REQUIRED_FINDING_KEYS='["severity","file","evidence","description","recommendation"]'
# The severities on which a finding must carry `impact` — the enum in the
# finding item's `if` in verdict-schema.json, whose `then` requires the key.
# Unlike the verdict/severity coupling further down, this conditional sits in
# the schema: it constrains one finding, never two levels at once, so the
# fallback mirrors it in a single clause and the drift test pins this list to
# the schema's enum. Same one-line rule as above.
readonly RC_IMPACT_SEVERITIES='["CRITICAL","HIGH"]'

# A `jsonschema` binary on PATH is not proof it's sourcemeta/jsonschema — other
# tools (e.g. the deprecated Python `jsonschema` package CLI) install a binary
# of the same name with an incompatible argument syntax (no `validate`
# subcommand), which would otherwise mark every instance invalid regardless of
# content. Self-test the exact invocation once against a known-valid instance
# and only trust the binary if it round-trips as expected.
_has_validator() {
	[[ -n "${_HAS_VALIDATOR:-}" ]] && {
		[[ "$_HAS_VALIDATOR" == "1" ]]
		return
	}
	_HAS_VALIDATOR=0
	if command -v jsonschema >/dev/null 2>&1; then
		local probe
		probe=$(mktemp)
		printf '%s' '{"agent":"probe","files_read":[],"verdict":"APPROVE","findings":[]}' >"$probe"
		jsonschema validate "$SCHEMA" "$probe" >/dev/null 2>&1 && _HAS_VALIDATOR=1
		rm -f "$probe"
	fi
	[[ "$_HAS_VALIDATOR" == "1" ]]
}

# Validate a JSON string against verdict-schema.json. Prefer sourcemeta/jsonschema
# (CLI: `jsonschema validate <schema> <instance-file>`, schema first, no stdin,
# exit 2 on invalid) when the self-test above confirms it behaves as expected.
# Otherwise degrade to a minimal jq structural check and warn loudly. Returns 0
# if valid, non-zero otherwise. Relies on being called in an `if ! validate ...`
# context so set -e is suspended inside.
validate() { # json_string
	local json="$1" tmp
	# shellcheck disable=SC2310 # _has_validator is a predicate; suspending set -e
	# inside it is the intended contract (see its self-test comment above).
	if _has_validator; then
		tmp=$(mktemp)
		printf '%s' "$json" >"$tmp"
		jsonschema validate "$SCHEMA" "$tmp" >/dev/null 2>&1
		local rc=$?
		rm -f "$tmp"
		return "$rc"
	fi
	if [[ "$_warned_no_validator" -eq 0 ]]; then
		echo "rc-warning: 'jsonschema' validator not found or incompatible; using minimal jq check. Install sourcemeta/jsonschema for full schema validation." >&2
		_warned_no_validator=1
	fi
	# Missing required keys are caught by the type assertions: an absent key
	# reads as null, whose type is "null", not "string"/"array".
	printf '%s' "$json" | jq -e \
		--argjson topkeys "$RC_TOP_KEYS" \
		--argjson fkeys "$RC_FINDING_KEYS" \
		--argjson cckeys "$RC_CONTEXT_CHECK_KEYS" \
		--argjson impactsevs "$RC_IMPACT_SEVERITIES" '
		# Exact membership. The obvious `[.x] | inside([...])` compares with
		# `contains`, which on strings is SUBSTRING containment — it accepted
		# "APPROV" as a verdict and "HIG"/"CRIT" as severities, and accepted
		# the empty string as both.
		def oneof($allowed): . as $v | any($allowed[]; . == $v);
		def nonempty_string: type == "string" and length > 0;
		# Schema says "integer"; jq has no integer type, so check it is whole.
		def integerish: type == "number" and (floor == .);
		(.agent | nonempty_string) and
		(.files_read | type) == "array" and all(.files_read[]; type == "string") and
		(.verdict | oneof(["APPROVE","REQUEST CHANGES"])) and
		(.findings | type) == "array" and
		((has("model") | not) or (.model | nonempty_string)) and
		((has("context_check") | not) or (.context_check | type == "object"
			and (([keys[]] - $cckeys) | length) == 0
			and (.file | nonempty_string) and (.evidence | nonempty_string)
			and (.line | integerish) and .line >= 1 and .line <= 10000000)) and
		(([keys[]] - $topkeys) | length) == 0 and
		(all(.findings[];
			(.severity | oneof(["CRITICAL","HIGH","MEDIUM","LOW"])) and
			(.file | nonempty_string) and
			(.evidence | nonempty_string) and
			(.description | nonempty_string) and
			(.recommendation | nonempty_string) and
			((.line == null) or (.line | integerish)) and
			((has("constraint") | not) or (.constraint | type) == "string") and
			# `title` is optional and unbounded in length. It carried a 120
			# character bound, which threw away a whole finding set over a
			# headline one character too long — a presentation concern answered
			# by discarding data. Its only consumer, rc_finding_block in
			# lib/render-findings.sh, renders it as a markdown bullet headline
			# that wraps, and the sibling path deriving a headline from
			# `description` is already uncapped. minLength stays: an empty
			# headline renders as an empty bold span.
			((has("title") | not) or (.title | nonempty_string)) and
			((has("impact") | not) or (.impact | nonempty_string)) and
			# A HIGH or CRITICAL must say who is hurt and how. An absent key
			# reads as null, which is not a non-empty string.
			(((.severity | oneof($impactsevs)) | not) or (.impact | nonempty_string)) and
			(([keys[]] - $fkeys) | length) == 0
		))
	' >/dev/null 2>&1
}

# Precise validation error to feed back on the ONE re-dispatch. Both paths name
# the offending field: sourcemeta's `--json` output when the binary is present
# (verified against 16.7.0 — `--json`/`-j` is a global option, and unlike the
# flagless form used by validate() it exits 0 and reports through the document,
# hence the `|| true`), and the field-by-field mirror below when it is not.
validate_error() { # json_string
	local json="$1" tmp msg
	# shellcheck disable=SC2310 # _has_validator is a predicate; see validate() above.
	if _has_validator; then
		tmp=$(mktemp)
		printf '%s' "$json" >"$tmp"
		msg=$(jsonschema validate "$SCHEMA" "$tmp" --json 2>&1 || true)
		rm -f "$tmp"
		printf '%s' "$msg"
		return
	fi
	# Fallback path: name the offending fields rather than listing every cause
	# the check has. The agent gets one re-dispatch and this is the only text
	# telling it which field to fix — a constant sentence naming three possible
	# causes misdiagnoses every defect that is not one of them, and an extra key
	# (the most common defect, because no document states the key set is closed)
	# is not one of them. The checks below mirror validate()'s jq expression
	# one for one, so the two cannot disagree about what is wrong.
	printf '%s' "$json" | jq -r \
		--argjson topkeys "$RC_TOP_KEYS" \
		--argjson reqtop "$RC_REQUIRED_TOP_KEYS" \
		--argjson fkeys "$RC_FINDING_KEYS" \
		--argjson reqf "$RC_REQUIRED_FINDING_KEYS" \
		--argjson cckeys "$RC_CONTEXT_CHECK_KEYS" \
		--argjson impactsevs "$RC_IMPACT_SEVERITIES" \
		--argjson sevs '["CRITICAL","HIGH","MEDIUM","LOW"]' \
		--argjson vrds '["APPROVE","REQUEST CHANGES"]' '
		def nonempty_string: type == "string" and length > 0;
		def integerish: type == "number" and (floor == .);
		def oneof($allowed): . as $v | any($allowed[]; . == $v);
		def quote($ks): $ks | map("`" + . + "`") | join(", ");
		if type != "object" then ["the block is a JSON \(type), not an object"]
		else
			[
				(if has("agent") and ((.agent | nonempty_string) | not)
					then "`agent` must be a non-empty string" else empty end),
				(if has("files_read") then
					if (.files_read | type) != "array"
						then "`files_read` must be an array of strings"
					elif ([.files_read[] | select(type != "string")] | length) > 0
						then "`files_read` must contain strings only"
					else empty end
				else empty end),
				(if has("verdict") and ((.verdict | oneof($vrds)) | not)
					then "`verdict` must be exactly \"APPROVE\" or \"REQUEST CHANGES\"" else empty end),
				(if has("findings") and ((.findings | type) != "array")
					then "`findings` must be an array (use [] for a clean review)" else empty end),
				(if has("model") and ((.model | nonempty_string) | not)
					then "`model` must be a non-empty string when present" else empty end),
				(if has("context_check") then
					if (.context_check | type) != "object" then "`context_check` must be an object"
					else ((.context_check | keys) - $cckeys) as $cx
						| ($cckeys - (.context_check | keys)) as $cm
						| if ($cx | length) > 0 then "context_check unrecognised key(s): " + quote($cx) + " — only " + quote($cckeys) + " are permitted"
						elif ($cm | length) > 0 then "context_check missing key(s): " + quote($cm)
						elif ((.context_check.line | integerish) and .context_check.line >= 1 and .context_check.line <= 10000000) | not then "context_check.line must be an integer from 1"
						elif ((.context_check.file | nonempty_string) and (.context_check.evidence | nonempty_string)) | not then "context_check.file and .evidence must be non-empty strings"
						else empty end
					end
				else empty end)
			]
			+ (($reqtop - keys) as $miss
				| if ($miss | length) > 0 then ["missing required key(s): " + quote($miss)] else [] end)
			+ ((keys - $topkeys) as $extra
				| if ($extra | length) > 0 then
					["unrecognised top-level key(s): " + quote($extra)
					+ " — the schema sets additionalProperties:false, so only "
					+ quote($topkeys) + " are permitted"]
				else [] end)
			+ (if (.findings | type) == "array" then
				[.findings | to_entries[] | .key as $i | .value as $f
					| if ($f | type) != "object"
						then "findings[\($i)] is a JSON \($f | type), not an object"
					else
						(($reqf - ($f | keys)) as $fmiss
							| if ($fmiss | length) > 0
								then "findings[\($i)] missing required key(s): " + quote($fmiss)
								else empty end),
						((($f | keys) - $fkeys) as $fx
							| if ($fx | length) > 0
								then "findings[\($i)] unrecognised key(s): " + quote($fx)
									+ " — only " + quote($fkeys) + " are permitted"
								else empty end),
						(if ($f | has("severity")) and (($f.severity | oneof($sevs)) | not)
							then "findings[\($i)].severity must be one of " + quote($sevs) else empty end),
						(if ($f | has("line")) and ($f.line != null) and (($f.line | integerish) | not)
							then "findings[\($i)].line must be an integer or null" else empty end),
						(if ($f | has("constraint")) and (($f.constraint | type) != "string")
							then "findings[\($i)].constraint must be a string" else empty end),
						(if ($f | has("title")) and (($f.title | nonempty_string) | not)
							then "findings[\($i)].title must be a non-empty string when present" else empty end),
						(if ($f | has("severity")) and ($f.severity | oneof($impactsevs)) and (($f.impact | nonempty_string) | not)
							then "findings[\($i)] is \($f.severity) and needs `impact`: a non-empty string naming who is affected, and how, if the change merges as-is"
						elif ($f | has("impact")) and (($f.impact | nonempty_string) | not)
							then "findings[\($i)].impact must be a non-empty string when present"
						else empty end),
						(["file", "evidence", "description", "recommendation"][] as $k
							| if ($f | has($k)) and (($f[$k] | nonempty_string) | not)
								then "findings[\($i)].\($k) must be a non-empty string" else empty end)
					end]
			else [] end)
		end
		# The mirror above is exhaustive, but it is a mirror: if validate()
		# ever rejects something no branch here names, say so plainly rather
		# than reporting an empty problem list as though nothing were wrong.
		| if length == 0
			then "Failed minimal structural check (missing required key, bad enum, or non-array findings)."
			else join("; ") end
	'
}

# The #101 context check reads the round index rc-build-context.sh wrote and
# matches quotes against the review tree with the same matcher evidence
# verification uses (lib/evidence.sh), so a context_check quote meets exactly
# the test a finding's evidence does, containment included. The root is only
# resolved here; a session without one fails the check when it is needed
# (CONTEXT_MISSING), not up front, because verdicts carrying findings and
# waived rounds never need it.
context_index="$session_dir/prompts/context.json"
review_root=$(rc_parse_kv "$session_dir/session.txt" "Review root")
root_abs=""
if [[ -n "$review_root" ]]; then
	root_abs=$(cd "$review_root" 2>/dev/null && pwd -P) || root_abs=""
fi
# shellcheck source=module/skills/review-council/scripts/lib/evidence.sh
source "$(dirname "$0")/lib/evidence.sh"

# Place a verified context_check quote against its round's hunks. Prints
# `clean` when an occurrence of <evidence> in <file> covers <line> and touches
# no hunk of that file, `in_hunk` when every occurrence covering <line> touches
# one, and `off_line` when none covers it. A quote that occurs exactly once
# names its own place, so a wrong <line> is not held against it (#113): that
# one occurrence is placed instead, `clean` becoming `moved <first> <last>`.
quote_span() { # file line evidence round
	local f="$1" line="$2" ev="$3" round="$4" nl k fpath occs occ hi seen=off_line
	# The quote spans one line per newline it holds, plus one. A single trailing
	# newline ends the last line rather than starting another, so it adds none.
	nl="${ev%$'\n'}"
	nl="${nl//[!$'\n']/}"
	k=$((${#nl} + 1))
	fpath=$(resolve "$f")
	# rc_evidence_status has just matched this quote, so a scan failure here is
	# not expected; if one happens, no occurrences reads as `off_line`.
	# shellcheck disable=SC2310 # the `||` is that fallback, so set -e is
	# suspended inside on purpose.
	occs=$(evidence_lines "$fpath" "$ev") || occs=""
	while IFS= read -r occ; do
		[[ -n "$occ" ]] || continue
		hi=$((occ + k - 1))
		[[ "$line" -ge "$occ" && "$line" -le "$hi" ]] || continue
		seen=in_hunk
		if jq -e --arg f "$f" --argjson lo "$occ" --argjson hi "$hi" \
			'[.files[] | select(.path == $f) | .hunks[]] | all(.[0] > $hi or .[1] < $lo)' <<<"$round" >/dev/null 2>&1; then
			echo clean
			return 0
		fi
	done <<<"$occs"
	if [[ "$seen" == off_line && "$occs" =~ ^[0-9]+$ ]]; then
		seen=$(quote_span "$f" "$occs" "$ev" "$round")
		[[ "$seen" != clean ]] || seen="moved $occs $((occs + k - 1))"
	fi
	echo "$seen"
}

# Render a reviewer-controlled string for a rejection detail: JSON-quoted, so a
# newline in it cannot add prose of the reviewer's choosing to the message the
# re-dispatch relays, and capped, so it cannot bury the rest of the detail.
detail_str() { # value
	jq -nr --arg s "$1" '$s[0:120] | tojson'
}

# Print the text of line <n> of changeset path <path> with surrounding
# whitespace trimmed; nothing when the line is blank or past the end. The file
# is read through resolve(), so awk never sees a bare operand it could take for
# an assignment or an option.
cited_line() { # path n
	local fpath text
	fpath=$(resolve "$1")
	text=$(LC_ALL=C awk -v n="$2" 'NR == n { print; exit }' "$fpath")
	text="${text#"${text%%[![:space:]]*}"}"
	printf '%s' "${text%"${text##*[![:space:]]}"}"
}

# Decide the context check for one zero-finding APPROVE. Sets `gate_out` to
# `ok` or `<REASON><TAB><detail>`, and on an accepted quote `gate_claim` to the
# round and cited line text the caller then records as held, and `gate_line`
# to the line the caller records when the quote's own line was wrong. Run directly
# rather than in a command substitution so that claim can reach the caller.
# Fails closed by construction: `ok` is assigned in exactly two places, after
# the waiver and after every check has passed; the caller presets a rejection
# and rejects anything but `ok`. Called under `||`, so a command that fails in
# here neither aborts the run nor returns early: it leaves a variable empty,
# and the next check rejects on that.
context_gate() { # rel block
	local rel="$1" block="$2" vd qdir round gate cc cfile qfile cline cev status span line_text claim holder n
	if ! jq -e '.rounds | type == "array"' "$context_index" >/dev/null 2>&1; then
		gate_out=$'CONTEXT_MISSING\t'"No usable prompts/context.json in this session, so a zero-finding APPROVE cannot be checked. Run rc-build-context.sh <session_dir> (SKILL.md Step 2.7), then re-run this extractor. No re-dispatch is needed."
		return 0
	fi
	vd=$(dirname "${rel#verdicts/}")
	[[ "$vd" == "." ]] && vd=""
	round=$(jq -c --arg d "$vd" 'first(.rounds[] | select(.verdict_dir == $d)) // empty' "$context_index" 2>/dev/null)
	# The index is readable, so rebuilding it would not add this directory: the
	# raw file is somewhere the batch plan never sends a reviewer. Still
	# CONTEXT_MISSING, as the fix is the orchestrator's and costs no re-dispatch.
	if [[ -z "$round" ]]; then
		qdir=$(detail_str "verdicts/${vd:+$vd/}")
		gate_out=$'CONTEXT_MISSING\t'"This raw file is in $qdir, a directory no round writes to, so prompts/context.json has nothing to check it against. Move it to the verdict path its round was planned with (the round's verdict_dir in prompts/context.json), then re-run this extractor. No re-dispatch is needed."
		return 0
	fi
	gate=$(jq -r '.gate' <<<"$round")
	if [[ "$gate" == "waived" ]]; then
		gate_out=ok
		return 0
	fi
	if [[ -z "$root_abs" ]]; then
		gate_out=$'CONTEXT_MISSING\t'"session.txt names no Review root that exists, so the context_check quote has no tree to be matched against. Restore the session's review root, then re-run this extractor. No re-dispatch is needed."
		return 0
	fi
	cc=$(jq -c '.context_check // empty' <<<"$block")
	if [[ -z "$cc" ]]; then
		gate_out=$'APPROVE_UNGROUNDED\t'"An APPROVE with no findings must carry \`context_check\`: {\"file\", \"line\", \"evidence\"} quoting a line of one of this round's files that lies outside the diff hunks. Your round's bundle lists the files and says whether the check is waived. If you found a defect after all, file it and keep or change the verdict to match."
		return 0
	fi
	cfile=$(jq -r '.file' <<<"$cc")
	cline=$(jq -r '.line' <<<"$cc")
	cev=$(jq -r '.evidence' <<<"$cc")
	qfile=$(detail_str "$cfile")
	# Reviewers given absolute paths in their prompt cite them back. Inside the
	# root, that is the same file as its repo-relative name; outside, it stays
	# absolute, matches no round file, and is refused. Containment is still
	# checked on the result by rc_evidence_status.
	if [[ "$cfile" == "$root_abs"/* ]]; then
		cfile="${cfile#"$root_abs"/}"
	elif [[ "$review_root" == /* && "$cfile" == "${review_root%/}"/* ]]; then
		cfile="${cfile#"${review_root%/}"/}"
	fi
	while [[ "$cfile" == ./* ]]; do cfile="${cfile#./}"; done
	# The minimal validator accepts 12.0 as an integer and jq prints it that
	# way; bash arithmetic below must only ever see a plain bounded integer.
	if [[ ! "$cline" =~ ^[1-9][0-9]{0,7}$ ]]; then
		gate_out=$'APPROVE_UNGROUNDED\t'"context_check.line must be a plain integer from 1."
		return 0
	fi
	if ! jq -e --arg f "$cfile" 'any(.files[]; .path == $f)' <<<"$round" >/dev/null 2>&1; then
		gate_out=$'APPROVE_UNGROUNDED\t'"context_check.file $qfile is not one of this round's files. Quote from a file listed in your round's bundle."
		return 0
	fi
	status=$(rc_evidence_status "$cfile" "" "$cev")
	if [[ "$status" != "verified" ]]; then
		gate_out=$'APPROVE_UNGROUNDED\t'"context_check.evidence does not verify against $qfile ($status). Copy a contiguous quote out of the file; never include the bundle's line numbers."
		return 0
	fi
	span=$(quote_span "$cfile" "$cline" "$cev" "$round")
	# A moved multi-line quote may start and end part-way through a line, so
	# it is recorded at the first line it quotes whole, if any.
	if [[ "$span" == moved* ]]; then
		read -r _ cline n <<<"$span"
		while [[ "$cline" -lt "$n" ]]; do
			line_text=$(cited_line "$cfile" "$cline")
			[[ -z "$line_text" || "$cev" != *"$line_text"* ]] || break
			cline=$((cline + 1))
		done
		gate_line="$cline"
		span=clean
	fi
	case "$span" in
	clean)
		# A fragment such as one letter of `package` occurs on line 1 of nearly
		# every file and is fileable without reading anything. The whole cited
		# line, trimmed, is not.
		line_text=$(cited_line "$cfile" "$cline")
		claim="$vd"$'\t'"$line_text"
		if [[ -z "$line_text" || "$cev" != *"$line_text"* ]]; then
			gate_out=$'APPROVE_UNGROUNDED\t'"context_check.evidence must include the whole cited line ($cline of $qfile, surrounding whitespace aside), and that line must not be blank. Cite a non-blank line and quote all of it."
		# Case-032: an orchestrator pasted one reviewer's passing quote into three
		# re-dispatch prompts, and all three passed. Each reviewer's quote has to
		# come from its own reading, so within a round a cited line's text is
		# held by the first accepted quote; text rather than position, since a
		# copied `}` passes at any line it occurs on. Its own reason, because
		# reviewers who read a small file independently pick the same obvious
		# line (#113): the collision gets a re-dispatch of its own rather than
		# spending the one a missing look costs.
		elif [[ -n "${context_claims["$claim"]:-}" ]]; then
			holder=$(detail_str "${context_claims["$claim"]}")
			gate_out=$'APPROVE_COLLIDED\t'"context_check cites the same line as ${holder}'s in this round. Each reviewer quotes a line it chose from its own reading of the files; quote a different line."
		else
			gate_out=ok
			gate_claim="$claim"
		fi
		;;
	off_line)
		gate_out=$'APPROVE_UNGROUNDED\t'"context_check.line $cline is not a line the quote occupies in $qfile, and the quote occurs there more than once. Cite the line the quote is on."
		;;
	*)
		gate_out=$'APPROVE_UNGROUNDED\t'"context_check quotes lines inside the diff hunks of $qfile; those are visible from the diff alone. Quote a line outside every hunk; the bundle marks which files have such lines."
		;;
	esac
}

invalid_json="[]"
valid_count=0
# {role, model} for every valid verdict that names its own model, applied to
# models.json once the loop is done.
model_reports="[]"
# Set once any block reaches validate(), whichever way it then went: the
# validation mode is a fact about this run only when something was validated.
validated_any=0
# Line text each accepted context_check holds, per round: "<verdict_dir><TAB>
# <text>" -> agent. Read by context_gate, written by the loop on acceptance.
declare -A context_claims=()
# The context check's duplicate rule lets the first accepted quote keep its
# line, so the order below decides who that is, and it must give the same
# answer on every run. Sorted, because readdir order is not the same on every
# filesystem (this container's and CI's differ). And a reviewer whose
# <agent>.json already carries the context_check its raw file still holds was
# accepted on an earlier run: it goes first. Otherwise a re-dispatched
# reviewer that picked the same line would take it on the next run, purely by
# sorting earlier, and revoke a verdict nothing was wrong with (case-032).
held_before() { # raw
	local json prev cur
	json="${1%.raw.md}.json"
	[[ -f "$json" ]] || return 1
	# The line is left out: the gate records a corrected one when the quote
	# names its own place (#113), so <agent>.json may differ from the raw file
	# there alone.
	prev=$(jq -c '.context_check // empty | del(.line)' "$json" 2>/dev/null) || return 1
	[[ -n "$prev" ]] || return 1
	# shellcheck disable=SC2310 # the caller's `if` suspends set -e here anyway.
	cur=$(extract_block "$1" | jq -c '.context_check // empty | del(.line)' 2>/dev/null) || return 1
	[[ "$cur" == "$prev" ]]
}
raw_files=()
while IFS= read -r -d '' f; do raw_files+=("$f"); done \
	< <(find "$vdir" -path "$vdir/_meta" -prune -o -name '*.raw.md' -type f -print0 2>/dev/null | LC_ALL=C sort -z || true)
held_raw=()
new_raw=()
for raw in "${raw_files[@]}"; do
	# shellcheck disable=SC2310 # a predicate: any failure inside means "not held".
	if held_before "$raw"; then held_raw+=("$raw"); else new_raw+=("$raw"); fi
done
raw_files=("${held_raw[@]}" "${new_raw[@]}")
for raw in "${raw_files[@]}"; do
	agent=$(basename "$raw")
	agent="${agent%.raw.md}"
	rel="${raw#"$session_dir"/}"
	# The symlink check's verdict is written by rc-check-symlinks.sh straight
	# to verdicts/, and its findings skip the evidence check because a script
	# computed them. A model-written raw file under that name would be turned
	# into the same json here: at the top level it overwrites the script's
	# verdict (a HIGH replaced by an empty APPROVE), and in a subsystem
	# directory it would carry in findings nobody computed. Refused at any
	# depth, before the block is read, and its json is never written.
	if [[ "$agent" == "$RC_SCRIPT_AGENT" ]]; then
		detail="${RC_SCRIPT_AGENT} is reserved: it names the symlink check, which rc-check-symlinks.sh writes to verdicts/${RC_SCRIPT_AGENT}.json itself. Reviewers never write it, and nothing was extracted from this file. Delete ${rel} and re-run the extractor; no dispatch is needed."
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "RESERVED_AGENT" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	# Revoke before judging: a json left from an earlier run would otherwise
	# outlive this run's refusal of the same reviewer, and verification reads
	# every json it finds. Only an accepted block writes it back below. After
	# the reserved-name check, whose json is the symlink script's own.
	rm -f "$(dirname "$raw")/$agent.json"
	block=$(extract_block "$raw")
	if [[ -z "$block" ]] || ! echo "$block" | jq -e . >/dev/null 2>&1; then
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "NO_JSON_BLOCK" --arg p "$rel" '. + [{agent:$a, reason:$r, path:$p}]')
		continue
	fi
	validated_any=1
	# shellcheck disable=SC2310 # validate() is documented as requiring an
	# `if ! validate ...` caller so set -e stays suspended inside it.
	if ! validate "$block"; then
		detail=$(validate_error "$block")
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "SCHEMA_INVALID" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	# Downstream keys each reviewer by filename, so a block whose `agent` names
	# someone else is one reviewer's verdict standing in for another's: that
	# reviewer's coverage vanishes and nothing reports it missing.
	claimed=$(jq -r '.agent' <<<"$block")
	if [[ -z "$agent" ]]; then
		detail="This file's name holds no agent, so the verdict cannot be attributed. Its block names \"${claimed}\": if that is right, move it to $(dirname "$rel")/${claimed}.raw.md."
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "AGENT_MISMATCH" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	if [[ "$claimed" != "$agent" ]]; then
		detail="This file is ${agent}'s, but its verdict block names agent \"${claimed}\". If the orchestrator wrote another reviewer's response here, rewrite the file with ${agent}'s own response. If ${agent} misnamed itself, ask it to re-emit the same block with \"agent\": \"${agent}\"."
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "AGENT_MISMATCH" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	# verdict-schema.json constrains `verdict` and `severity` independently and
	# never couples them, so an APPROVE filed over a CRITICAL finding validates.
	# Nothing downstream re-derives the verdict — rc-verify-evidence.sh copies it
	# verbatim — so the block would render as a green APPROVE header over a
	# verified CRITICAL. The coupling lives here rather than in the schema
	# because it ties the top-level verdict to every finding at once — a
	# cross-level rule, unlike the per-finding `impact` conditional — and
	# sitting outside validate() is what makes both validation paths reach it.
	# The reason is VERDICT_INCOHERENT, not SCHEMA_INVALID: the block IS
	# schema-valid, and a maintainer told otherwise would validate it by hand and
	# watch it pass.
	#
	# Both halves of the test below fail closed, and the polarity is why: jq
	# failing outright is caught by the `||`, and jq succeeding while printing
	# anything other than the two expected words is caught by testing `!= "no"`
	# rather than `== "yes"`. Do not "simplify" it to `== "yes"` — that turns
	# every unexpected output into an acceptance. Rejecting costs one
	# re-dispatch; accepting ships the mislabelled verdict.
	verdict_mismatch=$(printf '%s' "$block" | jq -r '
		if .verdict == "APPROVE"
			and (.findings | map(.severity) | any(. == "CRITICAL" or . == "HIGH"))
		then "yes" else "no" end
	' 2>/dev/null) || verdict_mismatch="yes"
	if [[ "$verdict_mismatch" != "no" ]]; then
		# Record the firing before filing the rejection. The rejection buys one
		# re-dispatch, the agent picks its own remedy, and the re-dispatch
		# overwrites both <agent>.raw.md and <agent>.json — so an agent that
		# resolves the gate by deleting its own CRITICAL leaves a session that
		# is byte-for-byte a reviewer which never found anything. This log is
		# the only place the original claim survives; verify.md Step 6 reads it
		# back and discloses every entry.
		#
		# It lives at the session root, not in verdicts/: every verdict
		# discovery in the pipeline globs verdicts/ (RC-4 exists because one of
		# those globs once ingested an orchestrator-written file that landed
		# there), and the extension keeps it clear of the '*.json' and
		# '*.raw.md' patterns besides. Appended, never rewritten — a second
		# firing for the same agent is a second event, not a duplicate to
		# collapse, and it is the FIRST record that carries what was originally
		# claimed. `jq -c` emits exactly one line, which is what makes append
		# the whole write. The block reaches jq on stdin rather than through
		# --argjson so a large verdict cannot hit the single-argv cap.
		fired_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
		printf '%s' "$block" | jq -c \
			--arg ts "$fired_at" \
			--arg agent "$agent" \
			--arg path "$rel" \
			'{ts: $ts, agent: $agent, path: $path, verdict: .verdict,
			  findings: [.findings[]
				| select(.severity == "CRITICAL" or .severity == "HIGH")
				| {severity, file, line, description}]}' \
			>>"$session_dir/gate-firings.jsonl"
		detail='Verdict/severity mismatch: verdict is "APPROVE" while findings still contain a CRITICAL or HIGH entry. A reviewer holding an unresolved CRITICAL or HIGH finding must return "REQUEST CHANGES". Either change the verdict to "REQUEST CHANGES", or — if the finding does not hold at that severity — drop it or lower its severity to MEDIUM/LOW and keep "APPROVE". Whichever you choose, say so in prose alongside the block: dropping the finding without a word erases it from the review entirely.'
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "VERDICT_INCOHERENT" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	# Issue #101. A zero-finding APPROVE is the verdict a reviewer that read only
	# the diff can still file with full confidence, and 20 dogfood dispatches
	# did exactly that. It must quote a line outside the hunks of a file in its
	# round. That proves less than a read, which the issue accepts, but it makes
	# a no-look APPROVE cost a look. Fails closed in the same polarity as the
	# coherence check above: anything but `ok`, including the function failing,
	# rejects. Not logged to gate-firings.jsonl, which keeps CRITICAL/HIGH
	# claims a re-dispatch could delete; this verdict carries none.
	#
	# Only code reviewers are gated: #101 is scoped to code review, and only
	# they are handed a bundle to quote from. Deep mode can mix code and spec
	# councils in one session, so the session's Mode is too coarse; the agent
	# is. It is this file's stem, which the orchestrator names, not the
	# reviewer, and the AGENT_MISMATCH check above has already held the
	# block's own `agent` to it. The test lists who is gated, so an
	# unexpected name skips the gate. That is acceptable: every code reviewer
	# in the roster is named divisor-*-code, a name outside it receives no
	# bundle it could quote, and the reserved-name and mismatch checks above
	# leave a reviewer no way to file under another stem.
	is_bare_approve=$(jq -r 'if .verdict == "APPROVE" and (.findings | length) == 0 then "yes" else "no" end' <<<"$block" 2>/dev/null) || is_bare_approve="yes"
	if [[ "$agent" == *-code && "$is_bare_approve" != "no" ]]; then
		# Preset to a rejection, so a context_gate that sets nothing rejects,
		# and forced back to it should the function itself fail. Its own
		# fail-closed design is described above the function.
		gate_unevaluated=$'APPROVE_UNGROUNDED\tThe context check could not be evaluated; re-emit the verdict with a valid context_check.'
		gate_out="$gate_unevaluated"
		gate_claim=""
		gate_line=""
		# shellcheck disable=SC2310 # set -e is suspended inside on purpose.
		context_gate "$rel" "$block" || gate_out="$gate_unevaluated"
		if [[ "$gate_out" != "ok" ]]; then
			invalid_json=$(jq --arg a "$agent" --arg r "${gate_out%%$'\t'*}" --arg d "${gate_out#*$'\t'}" --arg p "$rel" \
				'. + [{agent:$a, reason:$r, detail:$d, path:$p}]' <<<"$invalid_json")
			continue
		fi
		# Nothing after the gate refuses a verdict, so the line is held from
		# here; a refused quote never reaches this and reserves nothing.
		[[ -z "$gate_claim" ]] || context_claims["$gate_claim"]="$agent"
		[[ -z "$gate_line" ]] || block=$(jq -c --argjson l "$gate_line" '.context_check.line = $l' <<<"$block")
	fi
	echo "$block" | jq . >"$(dirname "$raw")/$agent.json"
	valid_count=$((valid_count + 1))
	# A reviewer's `model` is its own claim about itself, kept exactly as given:
	# the renderers allow-list it at display time, and a value trimmed here
	# could pass that check while differing from what the reviewer said.
	model_reports=$(printf '%s' "$block" | jq -c --arg a "$agent" --argjson acc "$model_reports" \
		'if has("model") then $acc + [{role: $a, model: .model}] else $acc end')
done

# Self-reported models go into that role's `reported` list, once each: deep
# mode dispatches one agent per subsystem, so a role can report more than one
# value, and a retry reports the same one again. A role with no entry gets one
# at `host default`, which is what rc-select-council.sh seeds for every
# reviewer. Only an existing models.json is updated: rc-select-council.sh
# creates it, and a file that does not parse as an array is left for its
# reseed rather than overwritten from here, with a warning that the reports
# were dropped.
models_file="$session_dir/models.json"
if [[ "$model_reports" != "[]" && -f "$models_file" ]]; then
	if ! jq -e 'type == "array"' "$models_file" >/dev/null 2>&1; then
		echo "rc-warning: self-reported models were not recorded: models.json is not an array" >&2
	else
		models_next=$(jq --argjson add "$model_reports" '
			reduce $add[] as $r (.;
				if any(.[]; type == "object" and .role == $r.role) then
					map(if type == "object" and .role == $r.role then
						.reported = ((if (.reported | type) == "array" then .reported else [] end)
							| if any(.[]; . == $r.model) then . else . + [$r.model] end)
					else . end)
				else . + [{role: $r.role, requested: "host default", reported: [$r.model]}] end)' "$models_file")
		models_tmp=$(mktemp "$session_dir/.models.XXXXXX")
		printf '%s\n' "$models_next" >"$models_tmp"
		mv -f "$models_tmp" "$models_file"
	fi
fi

# Which verdict-format check this run applied, for the verdict header. The
# session file keeps the worst of every run: batches and retries call this
# script more than once, and a header that said `full` because the last call
# happened to find the validator would hide the blocks the jq fallback passed.
# Written beside its final path and renamed into place, as the other _meta
# writers do, so a reader never sees a partial word.
schema_validation=""
if [[ "$validated_any" -eq 1 ]]; then
	# shellcheck disable=SC2310 # _has_validator is a predicate; see validate() above.
	if _has_validator; then
		schema_validation="full"
	else
		schema_validation="minimal"
	fi
	mkdir -p "$vdir/_meta"
	recorded_validation=""
	if [[ -f "$vdir/_meta/schema-validation.txt" ]]; then
		recorded_validation=$(head -n1 "$vdir/_meta/schema-validation.txt" 2>/dev/null) || recorded_validation=""
	fi
	if [[ "$recorded_validation" != "minimal" ]]; then
		validation_tmp=$(mktemp "$vdir/_meta/.schema-validation.XXXXXX")
		printf '%s\n' "$schema_validation" >"$validation_tmp"
		mv -f "$validation_tmp" "$vdir/_meta/schema-validation.txt"
	fi
fi

invalid_count=$(echo "$invalid_json" | jq 'length')
if [[ "$invalid_count" -gt 0 ]]; then
	read -r -d '' remediation <<'REM' || true
Your response must be exactly one fenced ```json block matching verdict-schema.json:
{ "agent": "...", "files_read": [...], "verdict": "APPROVE|REQUEST CHANGES",
  "model": "optional: your own model ID, only if you know it",
  "context_check": {"file": "...", "line": 88, "evidence": "..."},
  "findings": [ { "severity": "...", "file": "...", "line": 12, "evidence": "...",
  "constraint": "...", "description": "...", "recommendation": "...",
  "impact": "who is affected, and how, if this merges as-is",
  "title": "optional headline" } ] }
These are the only keys permitted at either level — the schema sets
"additionalProperties": false, so any other key is rejected, however useful it
looks. Put anything you would have added into `description`. Optional keys are
`model` and `context_check` at the top level and `line`, `title` and `constraint` in a finding.
`impact` is required on every HIGH or CRITICAL finding and optional on MEDIUM
and LOW. Every other key above is required.
`context_check` is required on a code reviewer's APPROVE with no findings,
unless your round's bundle says it is not required: quote a line outside the
diff hunks.
Emit only the block — no prose before or after.
Correct only the defect named above: re-emit the SAME findings, with the same
severities and the same evidence. This is a formatting repair, not a new review.
For APPROVE_UNGROUNDED and APPROVE_COLLIDED alone, the fix is to look past the diff: add the
`context_check` quote, or, if that look turns up a defect, file it and set the
verdict to match.
REM
	jq -n --argjson invalid "$invalid_json" --arg rem "$remediation" --argjson valid "$valid_count" \
		--arg sv "$schema_validation" \
		'{status:"extract_error", valid:$valid, invalid:$invalid, remediation:$rem}
		 + (if $sv == "" then {} else {schema_validation:$sv} end)'
	exit 0
fi

# Reaching here with zero valid blocks means no .raw.md exists at all — any
# file present would have landed in invalid[] above. Reviewers are read-only
# and return their verdicts; writing them is the orchestrator's job, so name
# the dispatched council (same `council // agents` read as rc-verify-evidence.sh)
# and say whose write is missing. No manifest, no claim about who was expected.
[[ "$valid_count" -eq 0 ]] && {
	extra="{}"
	manifest="$session_dir/session-manifest.json"
	# A manifest that parses but holds no list of names claims nothing either.
	[[ -f "$manifest" ]] && extra=$(jq -c 'if type == "object" then (.council // .agents) else null end
		| if type == "array" and all(type == "string") then {expected: .} else {} end' "$manifest")
	json_output "nothing_to_do" "No verdict blocks found: no .raw.md file exists under verdicts/. Reviewers return their verdicts; the orchestrator writes each one verbatim to its .raw.md path. If those responses are still held, write them and re-run extraction instead of re-dispatching." "$extra"
	exit 0
}
payload=$(jq -n --argjson v "$valid_count" --arg sv "$schema_validation" '{valid:$v, schema_validation:$sv}')
json_output "ok" "Extracted $valid_count verdict block(s)." "$payload"
exit 0
