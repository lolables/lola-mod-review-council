#!/usr/bin/env bash
# rc-apply-validation.sh: validator outcomes applied by finding id.
#
# The defect this suite was written for: validator outcomes were applied by
# hand, matched to findings by position, and a validator that returned two
# Guard outcomes transposed had a downgrade applied to the wrong finding. Every
# outcome now names its finding by id and echoes its file; anything that does
# not tie back cleanly is rejected by name rather than applied.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-apply-validation.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Two verified findings in different files, so a swapped pair of ids is
# detectable by the file echo, plus one already-stripped finding.
mk_session() {
	local s
	s=$(mktemp -d)
	mkdir -p "$s/verdicts/_meta"
	cat >"$s/verdicts/findings.json" <<'FJ'
{"verified":[
 {"id":"F1","agent":"divisor-guard-code","severity":"HIGH","file":"a.go","line":3,
  "evidence":"x := 1","description":"d1","recommendation":"r1",
  "verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
 {"id":"F2","agent":"divisor-guard-code","severity":"MEDIUM","file":"b.go","line":9,
  "evidence":"y := 2","description":"d2","recommendation":"r2",
  "verdict":"REQUEST CHANGES","status":"verified","provenance":{}}
],"correctable":[],
 "stripped":[{"id":"F3","agent":"divisor-sre-code","severity":"LOW","file":"c.go","line":1,
  "evidence":"z","description":"d3","recommendation":"r3","verdict":"APPROVE",
  "status":"stripped","reason":"FILE_NOT_FOUND","provenance":{}}],
 "total_findings":3,"duplicates_consolidated":0,"verdicts":{"divisor-guard-code":"REQUEST CHANGES"}}
FJ
	printf '%s' "$s"
}

validation() { # session json
	printf '%s\n' "$2" >"$1/verdicts/_meta/validation.json"
}

echo "Test 1: missing session -> nothing_to_do"
result=$(bash "$SCRIPT" /nonexistent)
assert_json_field "$result" "status" "nothing_to_do" "missing session"

echo "Test 2: CONFIRMED and CORRECTED applied by id"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F2","file":"b.go","result":"CORRECTED","reason":"risk needs a misconfig","corrections":{"severity":"LOW"}},
 {"id":"F1","file":"a.go","result":"CONFIRMED","reason":"grep shows x := 1 at a.go:3"}]}'
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "all findings resolved -> ok"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F1") | .provenance.validator.result' 'CONFIRMED' "F1 confirmed"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F1") | .severity' 'HIGH' "F1 severity untouched"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .severity' 'LOW' "F2 corrected to LOW"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .provenance.validator.changed_from.severity' 'MEDIUM' "F2 keeps its prior severity"
rm -rf "$s"

echo "Test 3: a transposed pair is rejected, never applied"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"severity":"LOW"}},
 {"id":"F2","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "retry" "nothing accepted -> retry"
assert_jq_str "$result" '[.rejected[] | .reason] | unique | tojson' '["FILE_MISMATCH"]' "both rejected as FILE_MISMATCH"
assert_jq_str "$result" '.pending | tojson' '["F1","F2"]' "both still pending"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F1") | .severity' 'HIGH' "F1 not downgraded by F2's answer"
rm -rf "$s"

echo "Test 4: each malformed entry is rejected by name"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F9","file":"a.go","result":"CONFIRMED","reason":"r"},
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"   "},
 {"id":"F2","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"file":"z.go"}},
 {"id":"F3","file":"c.go","result":"CONFIRMED","reason":"r"},
 {"id":7,"file":"a.go","result":"CONFIRMED","reason":"r"},
 "not an object"]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' \
	'["F9:UNKNOWN_ID","F1:NO_EVIDENCE","F2:BAD_CORRECTION","F3:UNKNOWN_ID","null:UNKNOWN_ID","null:BAD_RESULT"]' \
	"unknown id, bare retraction, forbidden field, non-verified id, non-string id, non-object"
rm -rf "$s"

echo "Test 5: duplicate ids reject every copy; bad result and bad severity rejected"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"},
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"e"},
 {"id":"F2","file":"b.go","result":"MAYBE","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' \
	'["F1:DUPLICATE_ID","F1:DUPLICATE_ID","F2:BAD_RESULT"]' "duplicates and bad result rejected"
validation "$s" '{"results":[{"id":"F2","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"severity":"SEVERE"}}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | .reason] | tojson' '["BAD_CORRECTION"]' "severity outside the enum rejected"
rm -rf "$s"

echo "Test 6: RETRACTED moves the finding to stripped with its evidence"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"x is reassigned","evidence":"a.go:4: x = 2"},
 {"id":"F2","file":"b.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$(<"$s/verdicts/findings.json")" '[.verified[].id] | tojson' '["F2"]' "F1 left verified"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.stripped[] | select(.id=="F1") | "\(.status):\(.reason):\(.provenance.validator.evidence)"' \
	'stripped:VALIDATOR_RETRACTED:a.go:4: x = 2' "F1 stripped as VALIDATOR_RETRACTED with evidence"
assert_jq_str "$result" '.retracted' '1' "retraction counted"
rm -rf "$s"

echo "Test 7: one retry, then --final marks the remainder UNVALIDATED"
s=$(mk_session)
validation "$s" '{"results":[{"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "retry" "unanswered F2 -> retry"
assert_jq_str "$result" '.pending | tojson' '["F2"]' "retry names only F2"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .provenance.validator // "none" | tostring' 'none' "first pass leaves F2 unmarked"
validation "$s" '{"results":[{"id":"F2","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s" --final)
assert_json_field "$result" "status" "ok" "--final -> ok"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .provenance.validator.result' 'UNVALIDATED' "F2 UNVALIDATED, still verified"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F1") | .provenance.validator.result' 'CONFIRMED' "F1 keeps its result"
rm -rf "$s"

echo "Test 8: an already-applied outcome is not applied twice"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F2","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"severity":"LOW"}},
 {"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
bash "$SCRIPT" "$s" >/dev/null
validation "$s" '{"results":[{"id":"F2","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"severity":"HIGH"}}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' '["F2:ALREADY_FINAL"]' "second outcome for F2 rejected"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .severity' 'LOW' "F2 keeps the first correction"
rm -rf "$s"

echo "Test 9: no validation.json, or invalid JSON, is no results — never a crash"
s=$(mk_session)
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "retry" "absent file -> retry"
assert_jq_str "$result" '.message | contains("No validation.json was found")' 'true' "absent file noted"
printf '{not json' >"$s/verdicts/_meta/validation.json"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "retry" "invalid JSON -> retry"
assert_jq_str "$result" '.message | contains("is not valid JSON")' 'true' "invalid JSON noted"
for body in '{"results":"x"}' '{"results":null}' '[]'; do
	printf '%s' "$body" >"$s/verdicts/_meta/validation.json"
	result=$(bash "$SCRIPT" "$s")
	assert_json_field "$result" "status" "retry" "$body -> retry"
	assert_jq_str "$result" '.message | contains("has no results array")' 'true' "$body noted as no results array"
done
rm -rf "$s"

echo "Test 10: findings without ids are refused"
s=$(mk_session)
jq '.verified[0] |= del(.id)' "$s/verdicts/findings.json" >"$s/f.tmp" && mv "$s/f.tmp" "$s/verdicts/findings.json"
before=$(<"$s/verdicts/findings.json")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "missing ids -> validation_error"
if [[ "$(<"$s/verdicts/findings.json")" == "$before" ]]; then
	echo "  PASS: findings.json untouched"
	PASS=$((PASS + 1))
else
	echo "  FAIL: findings.json changed"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 11: an unknown argument is refused"
s=$(mk_session)
result=$(bash "$SCRIPT" "$s" --finale)
assert_json_field "$result" "status" "validation_error" "typo in --final refused"
rm -rf "$s"

echo "Test 12: BAD_CORRECTION cases, and a null line accepted"
s=$(mk_session)
for c in '' ',"corrections":{}' ',"corrections":{"line":0}' ',"corrections":{"line":2.5}' \
	',"corrections":{"line":"5"}' ',"corrections":{"line":1e300}' ',"corrections":{"line":10000001}' ',"corrections":{"title":"  "}'; do
	validation "$s" '{"results":[{"id":"F2","file":"b.go","result":"CORRECTED","reason":"r"'"$c"'}]}'
	result=$(bash "$SCRIPT" "$s")
	assert_jq_str "$result" '[.rejected[] | .reason] | tojson' '["BAD_CORRECTION"]' "rejected: ${c:-no corrections}"
done
validation "$s" '{"results":[{"id":"F2","file":"b.go","result":"CORRECTED","reason":"r","corrections":{"line":null}}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '.corrected' '1' "null line accepted"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .provenance.validator.changed_from.line' '9' "prior line recorded"
rm -rf "$s"

echo "Test 13: an outcome for an already-retracted finding is ALREADY_FINAL"
s=$(mk_session)
validation "$s" '{"results":[{"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"e"}]}'
bash "$SCRIPT" "$s" >/dev/null
validation "$s" '{"results":[{"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' '["F1:ALREADY_FINAL"]' "retracted finding is final"
rm -rf "$s"

echo "Test 14: duplicate finding ids refuse to write"
# Duplicates among verified, and between verified and stripped, with the outcome
# kinds that would otherwise land on every copy of the id.
for dup in '.verified[1].id = "F1"' '.stripped[0].id = "F1"'; do
	for outcome in \
		'{"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"e"}' \
		'{"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"}'; do
		s=$(mk_session)
		jq "$dup" "$s/verdicts/findings.json" >"$s/f.tmp" && mv "$s/f.tmp" "$s/verdicts/findings.json"
		before=$(<"$s/verdicts/findings.json")
		validation "$s" '{"results":['"$outcome"']}'
		result=$(bash "$SCRIPT" "$s")
		assert_json_field "$result" "status" "validation_error" "$dup -> validation_error"
		assert_jq_str "$result" '.message | contains("duplicate finding ids")' 'true' "duplicate ids named"
		if [[ "$(<"$s/verdicts/findings.json")" == "$before" ]]; then
			echo "  PASS: findings.json byte-identical"
			PASS=$((PASS + 1))
		else
			echo "  FAIL: findings.json changed"
			FAIL=$((FAIL + 1))
		fi
		rm -rf "$s"
	done
done

echo "Test 14b: a rejected id is echoed at most 64 characters"
s=$(mk_session)
long=$(printf 'X%.0s' {1..200})
validation "$s" '{"results":[{"id":"'"$long"'","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '.rejected[0].id | length' '64' "long id truncated"
rm -rf "$s"

echo "Test 15: extra arguments are refused"
s=$(mk_session)
result=$(bash "$SCRIPT" "$s" --final extra)
assert_json_field "$result" "status" "validation_error" "third argument refused"
assert_jq_str "$result" '.message | contains("Usage:")' 'true' "usage shown"
rm -rf "$s"

echo "Test 16: a corrupt findings.json is refused as such"
s=$(mk_session)
printf '{not json' >"$s/verdicts/findings.json"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "invalid JSON -> validation_error"
assert_jq_str "$result" '.message | contains("not a valid findings document")' 'true' "invalid JSON named"
printf '{"verified":"x"}' >"$s/verdicts/findings.json"
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '.message | contains("not a valid findings document")' 'true' "non-array verified named"
rm -rf "$s"

echo "Test 17: blank or missing reason is BAD_RESULT"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"CONFIRMED","reason":"  "},
 {"id":"F2","file":"b.go","result":"CONFIRMED"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' '["F1:BAD_RESULT","F2:BAD_RESULT"]' "blank and missing reason rejected"
rm -rf "$s"

echo "Test 18: counts describe the document, not the pass"
s=$(mk_session)
validation "$s" '{"results":[{"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"}]}'
bash "$SCRIPT" "$s" >/dev/null
validation "$s" '{"results":[{"id":"F2","file":"b.go","result":"RETRACTED","reason":"r","evidence":"e"}]}'
result=$(bash "$SCRIPT" "$s" --final)
assert_jq_str "$result" '"\(.confirmed) \(.corrected) \(.retracted)"' '1 0 1' "final pass reports F1 confirmed and F2 retracted"
rm -rf "$s"

echo "Test 19: --dispute rejects a retraction, and the finding stays pending then UNVALIDATED"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"a.go:4: x = 2"},
 {"id":"F2","file":"b.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s" --dispute F1,F3)
assert_json_field "$result" "status" "retry" "disputed retraction -> retry"
assert_jq_str "$result" '[.rejected[] | "\(.id):\(.reason)"] | tojson' '["F1:DISPUTED"]' "rejected as DISPUTED"
assert_jq_str "$result" '.pending | tojson' '["F1"]' "F1 pending"
assert_jq_str "$(<"$s/verdicts/findings.json")" '[.verified[].id] | tojson' '["F1","F2"]' "F1 still verified"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F2") | .provenance.validator.result' 'CONFIRMED' "disputed id F3 with no entry is a no-op; F2 applied"
result=$(bash "$SCRIPT" "$s" --dispute F1 --final)
assert_json_field "$result" "status" "ok" "--final with --dispute -> ok"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id=="F1") | .provenance.validator.result' 'UNVALIDATED' "F1 UNVALIDATED, kept"
assert_jq_str "$result" '.unvalidated | tojson' '["F1"]' "unvalidated listed"
rm -rf "$s"

echo "Test 19b: a disputed id that names no finding refuses the whole pass"
# A typo in --dispute (F13 for F3) must not let the retraction it was meant to
# stop go through: the pass is refused before anything is applied.
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"r","evidence":"a.go:4: x = 2"}]}'
before=$(<"$s/verdicts/findings.json")
result=$(bash "$SCRIPT" "$s" --dispute F13)
assert_json_field "$result" "status" "validation_error" "unknown dispute id -> validation_error"
assert_jq_str "$result" '.message | contains("F13")' 'true' "message names the unknown id"
if [[ "$(<"$s/verdicts/findings.json")" == "$before" ]]; then
	echo "  PASS: findings.json untouched"
	PASS=$((PASS + 1))
else
	echo "  FAIL: findings.json changed despite the refusal"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 20: a disputed id with a CONFIRMED entry is applied normally"
s=$(mk_session)
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"CONFIRMED","reason":"r"},
 {"id":"F2","file":"b.go","result":"CONFIRMED","reason":"r"}]}'
result=$(bash "$SCRIPT" "$s" --dispute F1)
assert_json_field "$result" "status" "ok" "CONFIRMED not affected by --dispute"
rm -rf "$s"

echo "Test 21: malformed --dispute is refused"
s=$(mk_session)
for args in "--dispute" "--dispute f1" "--dispute F1,,F2" "--dispute F1;ls" "--dispute F1 --dispute F2" "--final --final"; do
	read -ra argv <<<"$args"
	result=$(bash "$SCRIPT" "$s" "${argv[@]}")
	assert_json_field "$result" "status" "validation_error" "refused: $args"
done
rm -rf "$s"

echo "Test S1: a script finding cannot be retracted or corrected (RC-076)"
# rc-verify-evidence.sh marks a script finding final (SCRIPT); any outcome for
# it is rejected, and it is never left pending or marked UNVALIDATED.
s=$(mk_session)
jq '.verified[0] |= (.agent = "rc-check-symlinks"
	| .provenance.validator = {result: "SCRIPT", reason: "computed from diff.patch"})' \
	"$s/verdicts/findings.json" >"$s/f.next"
mv "$s/f.next" "$s/verdicts/findings.json"
validation "$s" '{"results":[
 {"id":"F1","file":"a.go","result":"RETRACTED","reason":"the link is fine","evidence":"trust me"},
 {"id":"F2","file":"b.go","result":"CONFIRMED","reason":"y := 2 at b.go:9"}]}'
result=$(bash "$SCRIPT" "$s")
assert_jq_str "$result" '[.rejected[] | select(.id == "F1") | .reason] | join(",")' "ALREADY_FINAL" \
	"the retraction is rejected as already final"
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id == "F1") | .provenance.validator.result' \
	"SCRIPT" "F1 stays verified with its SCRIPT result"
assert_jq_str "$result" '.pending | index("F1") == null' "true" "F1 is not pending"
bash "$SCRIPT" "$s" --final >/dev/null
assert_jq_str "$(<"$s/verdicts/findings.json")" '.verified[] | select(.id == "F1") | .provenance.validator.result' \
	"SCRIPT" "the final pass does not mark F1 UNVALIDATED"
rm -rf "$s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
