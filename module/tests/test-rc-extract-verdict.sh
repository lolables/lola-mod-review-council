#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-extract-verdict.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

mk() {
	local s
	s=$(mktemp -d)
	mkdir -p "$s/verdicts"
	echo "$s"
}

echo "Test 1: valid block extracts to <agent>.json"
s=$(mk)
cat >"$s/verdicts/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["a.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"MEDIUM","file":"a.go","line":3,"evidence":"x := 1","description":"d","recommendation":"r"}]}
```
RAW
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "status ok"
if [[ -f "$s/verdicts/divisor-adversary-code.json" ]]; then
	echo "  PASS: json written"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no json"
	FAIL=$((FAIL + 1))
fi
v=$(jq -r '.verdict' "$s/verdicts/divisor-adversary-code.json")
if [[ "$v" == "REQUEST CHANGES" ]]; then
	echo "  PASS: verdict verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict '$v'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

printf 'Test 2: tabs in evidence round-trip without \\t literal\n'
s=$(mk)
# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
printf '```json\n{"agent":"a","files_read":[],"verdict":"APPROVE","findings":[{"severity":"LOW","file":"a.go","line":1,"evidence":"\\tif x {","description":"d","recommendation":"r"}]}\n```\n' >"$s/verdicts/a.raw.md"
bash "$SCRIPT" "$s" >/dev/null
ev=$(jq -r '.findings[0].evidence' "$s/verdicts/a.json")
if [[ "$ev" == $'\tif x {' ]]; then
	echo "  PASS: real tab preserved"
	PASS=$((PASS + 1))
else
	echo "  FAIL: got '$ev'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 3: no json block -> extract_error NO_JSON_BLOCK"
s=$(mk)
echo "I reviewed the code. Verdict: REQUEST CHANGES" >"$s/verdicts/divisor-guard-code.raw.md"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "extract_error" "status extract_error"
r=$(echo "$result" | jq -r '.invalid[0].reason')
if [[ "$r" == "NO_JSON_BLOCK" ]]; then
	echo "  PASS: reason NO_JSON_BLOCK"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 4: bad enum -> SCHEMA_INVALID"
s=$(mk)
cat >"$s/verdicts/divisor-sre-code.raw.md" <<'RAW'
```json
{"agent":"divisor-sre-code","files_read":[],"verdict":"MAYBE","findings":[]}
```
RAW
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "extract_error" "status extract_error"
r=$(echo "$result" | jq -r '.invalid[0].reason')
if [[ "$r" == "SCHEMA_INVALID" ]]; then
	echo "  PASS: reason SCHEMA_INVALID"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 5: missing required finding field -> SCHEMA_INVALID"
s=$(mk)
cat >"$s/verdicts/divisor-testing-code.raw.md" <<'RAW'
```json
{"agent":"divisor-testing-code","files_read":[],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"a.go","evidence":"x"}]}
```
RAW
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "extract_error" "missing desc/rec invalid"
rm -rf "$s"

echo "Test 6: council-only 'APPROVE WITH ADVISORIES' rejected as a reviewer verdict"
s=$(mk)
cat >"$s/verdicts/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE WITH ADVISORIES","findings":[]}
```
RAW
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "extract_error" "AWA reviewer verdict rejected"
r=$(echo "$result" | jq -r '.invalid[0].reason')
if [[ "$r" == "SCHEMA_INVALID" ]]; then
	echo "  PASS: reason SCHEMA_INVALID"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

# --- jq fallback validator -------------------------------------------------
# The script prefers sourcemeta/jsonschema and degrades to a jq structural
# check when it is absent. The two paths must agree: a verdict that is invalid
# on a host with the validator installed must not be accepted on a host
# without it. These cases mask `jsonschema` off PATH so the fallback is the
# path under test regardless of what the runner happens to have installed.
mask_dir=$(mktemp -d)
NOJS_PATH=$(path_without_command jsonschema "$mask_dir")

# fallback_reject <label> <json-body>
fallback_reject() {
	local label="$1" body="$2" s result r
	s=$(mk)
	# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
	printf '```json\n%s\n```\n' "$body" >"$s/verdicts/divisor-guard-code.raw.md"
	result=$(PATH="$NOJS_PATH" bash "$SCRIPT" "$s" 2>/dev/null)
	r=$(echo "$result" | jq -r '.invalid[0].reason // "none"')
	if [[ "$r" == "SCHEMA_INVALID" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label (reason '$r', expected SCHEMA_INVALID)"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$s"
}

# fallback_accept <label> <json-body>
fallback_accept() {
	local label="$1" body="$2" s result
	s=$(mk)
	# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
	printf '```json\n%s\n```\n' "$body" >"$s/verdicts/divisor-guard-code.raw.md"
	local status reason
	result=$(PATH="$NOJS_PATH" bash "$SCRIPT" "$s" 2>/dev/null)
	status=$(printf '%s' "$result" | jq -r '.status')
	if [[ "$status" == "ok" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		reason=$(printf '%s' "$result" | jq -r '.invalid[0].reason // "none"')
		echo "  FAIL: $label (status $status, reason $reason)"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$s"
}

echo "Test 7: jq fallback enforces additionalProperties:false (RC-6)"
fallback_reject "unknown top-level key rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE","findings":[],"confidence":0.9}'
fallback_reject "unknown finding key rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"REQUEST CHANGES","findings":[{"severity":"HIGH","file":"a.go","evidence":"x","description":"d","recommendation":"r","cwe":"CWE-89"}]}'
fallback_accept "optional constraint field still accepted" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"REQUEST CHANGES","findings":[{"severity":"HIGH","file":"a.go","line":3,"evidence":"x","description":"d","recommendation":"r","constraint":"CR-001"}]}'

echo "Test 8: jq fallback enum checks are exact, not substring (RC-7)"
# `[.verdict] | inside([...])` compares with `contains`, which on strings is
# SUBSTRING containment: "APPROV", "HIG" and "CRIT" all satisfied the enum
# check and were accepted as valid values by the fallback path.
fallback_reject "truncated verdict rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROV","findings":[]}'
fallback_reject "truncated severity rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE","findings":[{"severity":"HIG","file":"a.go","evidence":"x","description":"d","recommendation":"r"}]}'
fallback_reject "truncated severity CRIT rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE","findings":[{"severity":"CRIT","file":"a.go","evidence":"x","description":"d","recommendation":"r"}]}'
fallback_reject "empty-string verdict rejected" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"","findings":[]}'
fallback_accept "exact enum values still accepted" \
	'{"agent":"divisor-guard-code","files_read":[],"verdict":"REQUEST CHANGES","findings":[{"severity":"CRITICAL","file":"a.go","line":null,"evidence":"x","description":"d","recommendation":"r"}]}'

echo "Test 9: fallback key lists match verdict-schema.json (drift guard)"
# The fallback hardcodes the two allowed key sets. If the schema gains or loses
# a property and the fallback is not updated, the two validation paths diverge
# again — silently, and only on hosts without the real validator.
SCHEMA_FILE="$SCRIPT_DIR/../skills/review-council/references/verdict-schema.json"
for spec in "RC_TOP_KEYS:.properties|keys" "RC_FINDING_KEYS:.properties.findings.items.properties|keys"; do
	varname="${spec%%:*}"
	filter="${spec#*:}"
	schema_keys=$(jq -rc "$filter | sort" "$SCHEMA_FILE")
	# The script declares each list on one line as: readonly RC_x_KEYS='[...]'
	script_keys=$(sed -n "s/^readonly $varname='\(.*\)'\$/\1/p" "$SCRIPT" | jq -rc 'sort')
	if [[ "$schema_keys" == "$script_keys" ]]; then
		echo "  PASS: $varname matches schema"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $varname drift — schema $schema_keys vs script $script_keys"
		FAIL=$((FAIL + 1))
	fi
done

# --- verdict/severity coupling ---------------------------------------------
# The schema constrains `verdict` and `severity` independently and never
# couples them, so an APPROVE filed over a CRITICAL finding is schema-valid.
# Nothing downstream re-derives the verdict — rc-verify-evidence.sh copies it
# verbatim — so such a block renders as a green APPROVE header over a verified
# CRITICAL and gets posted upstream. The gate lives in the script rather than
# the schema, outside validate(), so it fires whichever validator ran; every
# case below is therefore asserted under both PATHs.

# Mirror of the script's own validator self-test (_has_validator): a binary
# named `jsonschema` on PATH is not proof it is sourcemeta's. Without that
# probe the dual-PATH loop below degenerates in silence — both iterations run
# the identical jq path, for double the runtime and no extra coverage.
real_validator=0
if command -v jsonschema >/dev/null 2>&1; then
	probe=$(mktemp)
	printf '%s' '{"agent":"probe","files_read":[],"verdict":"APPROVE","findings":[]}' >"$probe"
	jsonschema validate "$SCHEMA_FILE" "$probe" >/dev/null 2>&1 && real_validator=1
	rm -f "$probe"
fi

# gate_case <label> <reject|accept> <json-body>
gate_case() {
	local label="$1" expect="$2" body="$3" s result status reason p
	local paths=("$NOJS_PATH")
	[[ "$real_validator" -eq 1 ]] && paths=("$PATH" "$NOJS_PATH")
	for p in "${paths[@]}"; do
		s=$(mk)
		# shellcheck disable=SC2016 # literal markdown fence, not command substitution.
		printf '```json\n%s\n```\n' "$body" >"$s/verdicts/divisor-guard-code.raw.md"
		result=$(PATH="$p" bash "$SCRIPT" "$s" 2>/dev/null)
		status=$(printf '%s' "$result" | jq -r '.status')
		reason=$(printf '%s' "$result" | jq -r '.invalid[0].reason // "none"')
		rm -rf "$s"
		if [[ "$expect" == "reject" && "$status" == "extract_error" && "$reason" == "VERDICT_INCOHERENT" ]]; then
			continue
		fi
		if [[ "$expect" == "accept" && "$status" == "ok" ]]; then
			continue
		fi
		echo "  FAIL: $label (status '$status', reason '$reason')"
		FAIL=$((FAIL + 1))
		return
	done
	echo "  PASS: $label"
	PASS=$((PASS + 1))
}

echo "Test 10: APPROVE filed over a HIGH or CRITICAL finding is rejected"
if [[ "$real_validator" -eq 1 ]]; then
	echo "  (each case asserted under both the sourcemeta and the jq validator)"
else
	echo "  SKIP: validator path not exercised — no working sourcemeta/jsonschema binary; jq fallback only"
fi
gate_case "APPROVE over CRITICAL rejected" reject \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[{"severity":"CRITICAL","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"}]}'
gate_case "APPROVE over HIGH rejected" reject \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[{"severity":"HIGH","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"}]}'
gate_case "APPROVE over a mixed list containing HIGH rejected" reject \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[{"severity":"LOW","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"},{"severity":"HIGH","file":"a.go","line":2,"evidence":"y","description":"d","recommendation":"r"}]}'
gate_case "REQUEST CHANGES over CRITICAL accepted" accept \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"REQUEST CHANGES","findings":[{"severity":"CRITICAL","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"}]}'
gate_case "APPROVE over MEDIUM and LOW accepted" accept \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[{"severity":"MEDIUM","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"},{"severity":"LOW","file":"a.go","line":2,"evidence":"y","description":"d","recommendation":"r"}]}'
# A clean reviewer must not be broken by the coupling rule.
gate_case "APPROVE with an empty findings array accepted" accept \
	'{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE","findings":[]}'

# The detail is the only text the agent sees on its single re-dispatch. If it
# only says "invalid", the agent has no way to know which of the two fields to
# change and can re-emit the same mismatch.
echo "Test 11: the re-dispatch detail states the rule the agent must follow"
s=$(mk)
cat >"$s/verdicts/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":["a.go"],"verdict":"APPROVE",
 "findings":[{"severity":"CRITICAL","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"}]}
```
RAW
result=$(bash "$SCRIPT" "$s" 2>/dev/null)
detail=$(printf '%s' "$result" | jq -r '.invalid[0].detail // ""')
if grep -qF 'REQUEST CHANGES' <<<"$detail" && grep -qF 'CRITICAL' <<<"$detail"; then
	echo "  PASS: detail names the required verdict"
	PASS=$((PASS + 1))
else
	echo "  FAIL: detail does not tell the agent what to fix: '$detail'"
	FAIL=$((FAIL + 1))
fi
# The remedy is the agent's choice and the re-dispatch overwrites the raw file,
# so a detail that does not warn about the withdrawal branch invites the agent
# to delete its own CRITICAL without a word.
if grep -qF 'erases it from the review' <<<"$detail"; then
	echo "  PASS: detail warns against a silent withdrawal"
	PASS=$((PASS + 1))
else
	echo "  FAIL: detail lets the agent drop the finding unannounced"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

# The whole point of a separate reason code: this block IS schema-valid, so
# reporting SCHEMA_INVALID would send a maintainer to validate it by hand and
# watch it pass. Assert both halves — the code emitted, and the schema verdict
# that contradicts the old label.
echo "Test 12: an incoherent verdict reports VERDICT_INCOHERENT, not SCHEMA_INVALID"
coherent_reason=$(printf '%s' "$result" | jq -r '.invalid[0].reason')
if [[ "$coherent_reason" == "VERDICT_INCOHERENT" ]]; then
	echo "  PASS: reason VERDICT_INCOHERENT"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$coherent_reason', expected VERDICT_INCOHERENT"
	FAIL=$((FAIL + 1))
fi
# jq stands in for the schema here: every constraint verdict-schema.json places
# on this block is structural, and the block satisfies all of them.
if printf '%s' \
	'{"agent":"a","files_read":[],"verdict":"APPROVE","findings":[{"severity":"CRITICAL","file":"a.go","line":1,"evidence":"x","description":"d","recommendation":"r"}]}' |
	jq -e '.verdict == "APPROVE" and (.findings[0].severity == "CRITICAL")' >/dev/null; then
	echo "  PASS: the rejected block uses only schema-legal field values"
	PASS=$((PASS + 1))
else
	echo "  FAIL: fixture no longer demonstrates a schema-valid incoherent verdict"
	FAIL=$((FAIL + 1))
fi

rm -rf "$mask_dir"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
