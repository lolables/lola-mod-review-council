#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-extract-verdict.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
