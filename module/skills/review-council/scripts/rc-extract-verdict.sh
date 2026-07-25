#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors

# rc-extract-verdict.sh <session_dir>
# For each verdicts/<agent>.raw.md (raw agent output), extract the fenced ```json
# block and validate it structurally. Writes verdicts/<agent>.json on success.
# Emits a JSON summary. Invalid/missing blocks are reported for one re-dispatch.

session_dir="${1:-}"
[[ -n "$session_dir" && -d "$session_dir" ]] || { json_output "skip" "Session directory not found."; exit 0; }
vdir="$session_dir/verdicts"
[[ -d "$vdir" ]] || { json_output "nothing_to_do" "No verdicts directory."; exit 0; }

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

# A `jsonschema` binary on PATH is not proof it's sourcemeta/jsonschema — other
# tools (e.g. the deprecated Python `jsonschema` package CLI) install a binary
# of the same name with an incompatible argument syntax (no `validate`
# subcommand), which would otherwise mark every instance invalid regardless of
# content. Self-test the exact invocation once against a known-valid instance
# and only trust the binary if it round-trips as expected.
_has_validator() {
	[[ -n "${_HAS_VALIDATOR:-}" ]] && { [[ "$_HAS_VALIDATOR" == "1" ]]; return; }
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
	if _has_validator; then
		tmp=$(mktemp)
		printf '%s' "$json" > "$tmp"
		jsonschema validate "$SCHEMA" "$tmp" >/dev/null 2>&1
		local rc=$?
		rm -f "$tmp"
		return $rc
	fi
	if [[ "$_warned_no_validator" -eq 0 ]]; then
		echo "rc-warning: 'jsonschema' validator not found or incompatible; using minimal jq check. Install sourcemeta/jsonschema for full schema validation." >&2
		_warned_no_validator=1
	fi
	printf '%s' "$json" | jq -e '
		(.agent | type) == "string" and
		(.files_read | type) == "array" and
		([.verdict] | inside(["APPROVE","REQUEST CHANGES"])) and
		(.findings | type) == "array" and
		(all(.findings[];
			([.severity] | inside(["CRITICAL","HIGH","MEDIUM","LOW"])) and
			(.file | type) == "string" and (.file | length) > 0 and
			(.evidence | type) == "string" and (.evidence | length) > 0 and
			(.description | type) == "string" and
			(.recommendation | type) == "string" and
			((.line == null) or (.line | type) == "number")
		))
	' >/dev/null 2>&1
}

# Precise validation error to feed back on the ONE re-dispatch. Uses the
# validator's --json output when available; terse note under the jq path.
validate_error() { # json_string
	local json="$1" tmp msg
	if _has_validator; then
		tmp=$(mktemp); printf '%s' "$json" > "$tmp"
		msg=$(jsonschema validate "$SCHEMA" "$tmp" --json 2>&1 || true)
		rm -f "$tmp"; printf '%s' "$msg"
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
	if ! validate "$block"; then
		detail=$(validate_error "$block")
		invalid_json=$(echo "$invalid_json" | jq --arg a "$agent" --arg r "SCHEMA_INVALID" --arg d "$detail" --arg p "$rel" '. + [{agent:$a, reason:$r, detail:$d, path:$p}]')
		continue
	fi
	echo "$block" | jq . >"$(dirname "$raw")/$agent.json"
	valid_count=$((valid_count + 1))
done

if [[ "$(echo "$invalid_json" | jq 'length')" -gt 0 ]]; then
	read -r -d '' remediation <<'REM' || true
Your response must be exactly one fenced ```json block matching verdict-schema.json:
{ "agent": "...", "files_read": [...], "verdict": "APPROVE|REQUEST CHANGES",
  "findings": [ { "severity": "...", "file": "...", "line": 12, "evidence": "...",
  "constraint": "...", "description": "...", "recommendation": "..." } ] }
Emit only the block — no prose before or after. Re-emit your full verdict now.
REM
	jq -n --argjson invalid "$invalid_json" --arg rem "$remediation" --argjson valid "$valid_count" \
		'{status:"extract_error", valid:$valid, invalid:$invalid, remediation:$rem}'
	exit 0
fi

[[ "$valid_count" -eq 0 ]] && { json_output "nothing_to_do" "No verdict blocks found."; exit 0; }
json_output "ok" "Extracted $valid_count verdict block(s)." "$(jq -n --argjson v "$valid_count" '{valid:$v}')"
exit 0
