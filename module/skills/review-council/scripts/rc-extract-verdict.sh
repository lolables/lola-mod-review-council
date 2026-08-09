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
			# `title` is optional, but when present the 120 bound has to hold
			# HERE, not only under a real validator. This fallback is the boundary
			# on every host without sourcemeta/jsonschema, and the bound exists so
			# that no renderer downstream has to truncate — an unenforced limit
			# just moves the arbitrary cut somewhere less visible.
			((has("title") | not) or ((.title | nonempty_string) and (.title | length) <= 120)) and
			(([keys[]] - $fkeys) | length) == 0
		))
	' >/dev/null 2>&1
}

# Precise validation error to feed back on the ONE re-dispatch. Uses the
# validator's --json output when available; terse note under the jq path.
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
	printf 'Failed minimal structural check (missing required key, bad enum, or non-array findings).'
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
  "title": "optional headline, max 120 characters" } ] }
Emit only the block — no prose before or after. Re-emit your full verdict now.
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
