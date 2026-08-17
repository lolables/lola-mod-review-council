#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-extract-verdict.sh <session_dir>
# For each verdicts/<agent>.raw.md (raw agent output), extract the fenced ```json
# block, validate it structurally, then enforce the one invariant the schema
# cannot express: a verdict of APPROVE may not be filed over a CRITICAL or HIGH
# finding. Writes verdicts/<agent>.json on success. Emits a JSON summary.
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

# Extract the first fenced ```json ... ``` block from a file to stdout.
extract_block() { # file
	awk '
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
readonly RC_TOP_KEYS='["agent","files_read","verdict","findings"]'
readonly RC_FINDING_KEYS='["severity","file","line","title","evidence","constraint","description","recommendation"]'
# The subset of RC_FINDING_KEYS that "required" in verdict-schema.json names.
# Every top-level key is required, so RC_TOP_KEYS doubles as that list; findings
# are the only level where the two differ (`line`, `title` and `constraint` are
# optional). Same one-line rule as above — the schema-drift test reads it.
readonly RC_REQUIRED_FINDING_KEYS='["severity","file","evidence","description","recommendation"]'

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
		--argjson fkeys "$RC_FINDING_KEYS" '
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
		--argjson fkeys "$RC_FINDING_KEYS" \
		--argjson reqf "$RC_REQUIRED_FINDING_KEYS" \
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
					then "`findings` must be an array (use [] for a clean review)" else empty end)
			]
			+ (($topkeys - keys) as $miss
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

invalid_json="[]"
valid_count=0
raw_files=()
while IFS= read -r -d '' f; do raw_files+=("$f"); done \
	< <(find "$vdir" -name '*.raw.md' -type f -print0 2>/dev/null || true)
for raw in "${raw_files[@]}"; do
	agent=$(basename "$raw" .raw.md)
	rel="${raw#"$session_dir"/}"
	block=$(extract_block "$raw")
	if [[ -z "$block" ]] || ! echo "$block" | jq -e . >/dev/null 2>&1; then
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "NO_JSON_BLOCK" --arg p "$rel" '. + [{agent:$a, reason:$r, path:$p}]')
		continue
	fi
	# shellcheck disable=SC2310 # validate() is documented as requiring an
	# `if ! validate ...` caller so set -e stays suspended inside it.
	if ! validate "$block"; then
		detail=$(validate_error "$block")
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "SCHEMA_INVALID" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	# verdict-schema.json constrains `verdict` and `severity` independently and
	# never couples them, so an APPROVE filed over a CRITICAL finding validates.
	# Nothing downstream re-derives the verdict — rc-verify-evidence.sh copies it
	# verbatim — so the block would render as a green APPROVE header over a
	# verified CRITICAL. The coupling lives here rather than in the schema
	# because the jq fallback would have to mirror a draft-07 if/then and the two
	# would drift; sitting outside validate() is what makes both validation paths
	# reach it. The reason is VERDICT_INCOHERENT, not SCHEMA_INVALID: the block
	# IS schema-valid, and a maintainer told otherwise would validate it by hand
	# and watch it pass.
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
	echo "$block" | jq . >"$(dirname "$raw")/$agent.json"
	valid_count=$((valid_count + 1))
done

invalid_count=$(echo "$invalid_json" | jq 'length')
if [[ "$invalid_count" -gt 0 ]]; then
	read -r -d '' remediation <<'REM' || true
Your response must be exactly one fenced ```json block matching verdict-schema.json:
{ "agent": "...", "files_read": [...], "verdict": "APPROVE|REQUEST CHANGES",
  "findings": [ { "severity": "...", "file": "...", "line": 12, "evidence": "...",
  "constraint": "...", "description": "...", "recommendation": "...",
  "title": "optional headline" } ] }
These are the only keys permitted at either level — the schema sets
"additionalProperties": false, so any other key is rejected, however useful it
looks. Put anything you would have added into `description`. Optional keys are
`line`, `title` and `constraint`; every other key above is required.
Emit only the block — no prose before or after.
Correct only the defect named above: re-emit the SAME findings, with the same
severities and the same evidence. This is a formatting repair, not a new review.
REM
	jq -n --argjson invalid "$invalid_json" --arg rem "$remediation" --argjson valid "$valid_count" \
		'{status:"extract_error", valid:$valid, invalid:$invalid, remediation:$rem}'
	exit 0
fi

[[ "$valid_count" -eq 0 ]] && {
	json_output "nothing_to_do" "No verdict blocks found."
	exit 0
}
payload=$(jq -n --argjson v "$valid_count" '{valid:$v}')
json_output "ok" "Extracted $valid_count verdict block(s)." "$payload"
exit 0
