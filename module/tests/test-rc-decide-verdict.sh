#!/usr/bin/env bash
# rc-decide-verdict.sh records the council verdict that the verified findings
# decide (phases/report.md "Final Verdict Determination"): any verified
# CRITICAL or HIGH -> REQUEST CHANGES; verified findings, none blocking ->
# APPROVE WITH ADVISORIES; none -> APPROVE. No findings.json: no verdict.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-decide-verdict.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# A session whose findings.json holds verified findings of <severities>
# (space-separated), plus one stripped HIGH and one correctable CRITICAL that
# must never count.
with_verified() { # severities...
	local s
	s=$(new_session)
	jq -n --args '{
		verified: [$ARGS.positional[] | {agent: "divisor-guard-code", severity: ., file: "a.go", line: 1}],
		correctable: [{agent: "divisor-guard-code", severity: "CRITICAL", file: "b.go", line: 1}],
		stripped: [{agent: "divisor-guard-code", severity: "HIGH", file: "c.go", line: 1, reason: "FILE_NOT_FOUND"}],
		verdicts: {}
	}' "$@" >"$s/verdicts/findings.json"
	printf '%s' "$s"
}

decide() { # severities... -> recorded verdict
	local s v
	s=$(with_verified "$@")
	bash "$SCRIPT" "$s" >/dev/null
	v=$(cat "$s/verdict.txt")
	rm -rf "$s"
	printf '%s' "$v"
}

echo "Test 1: severity decides the verdict (RC-077)"
verdict=$(decide HIGH LOW)
assert_equals "$verdict" "REQUEST CHANGES" "a verified HIGH blocks"
verdict=$(decide CRITICAL)
assert_equals "$verdict" "REQUEST CHANGES" "a verified CRITICAL blocks"
verdict=$(decide MEDIUM LOW)
assert_equals "$verdict" "APPROVE WITH ADVISORIES" "MEDIUM and LOW are advisory"
verdict=$(decide)
assert_equals "$verdict" "APPROVE" "no verified finding approves; stripped and correctable do not count"

echo "Test 2: the status names the verdict, written as one line"
s=$(with_verified HIGH)
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "status is ok"
assert_json_field "$result" "verdict" "REQUEST CHANGES" "payload carries the verdict"
lines=$(wc -l <"$s/verdict.txt" | tr -d ' ')
assert_equals "$lines" "1" "verdict.txt is exactly one line"

echo "Test 3: a re-run on its own output changes nothing"
first=$(cat "$s/verdict.txt")
bash "$SCRIPT" "$s" >/dev/null
again=$(cat "$s/verdict.txt")
assert_equals "$again" "$first" "idempotent"
rm -rf "$s"

echo "Test 4: no findings.json, no verdict; a stale one is removed"
s=$(new_session)
echo "APPROVE" >"$s/verdict.txt"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"
if [[ ! -e "$s/verdict.txt" ]]; then
	echo "  PASS: no verdict.txt is left to read as a decision"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a verdict.txt survived with nothing to decide it from"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 5: an unreadable findings.json changes nothing"
s=$(new_session)
echo '{"verified": "not a list"}' >"$s/verdicts/findings.json"
echo "REQUEST CHANGES" >"$s/verdict.txt"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "status is validation_error"
kept=$(cat "$s/verdict.txt")
assert_equals "$kept" "REQUEST CHANGES" "verdict.txt is unchanged"
rm -rf "$s"

echo "Test 6: missing session"
result=$(bash "$SCRIPT" /nonexistent)
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
