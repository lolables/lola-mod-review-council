#!/usr/bin/env bash
# rc-apply-corrections.sh: the correction round applied by finding id, with
# every corrected quote re-checked by the evidence matcher.
#
# The defect this suite was written for: the correction round had no script.
# Orchestrators moved corrected findings from `correctable` to `verified` by
# editing findings.json by hand, and nothing re-checked the new quote, so a
# correction that still did not match the source shipped as verified evidence.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-apply-corrections.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# A review root with three source files, and a session whose findings.json has
# one verified finding and four correctable ones: two whose quote was not found
# (F2, F4), one cited at the wrong line (F3) and one that will go unanswered (F5).
mk_session() { # dir for the review root
	local s="$1/session" root="$1/root"
	mkdir -p "$s/verdicts/_meta" "$root"
	printf 'package a\n\nfunc A() { x := 1 }\n' >"$root/a.go"
	printf 'package b\n\nfunc B() {\n\ty := 2\n}\n' >"$root/b.go"
	# z := 3 lands on line 22, far outside the +-5 window around F3's line 2.
	{
		echo 'package c'
		for _ in $(seq 1 20); do echo; done
		echo 'func C() { z := 3 }'
	} >"$root/c.go"
	cat >"$s/verdicts/findings.json" <<'FJ'
{"verified":[
 {"id":"F1","agent":"divisor-guard-code","severity":"HIGH","file":"a.go","line":3,
  "evidence":"x := 1","description":"d1","recommendation":"r1","verdict":"REQUEST CHANGES",
  "status":"verified","provenance":{}}],
 "correctable":[
 {"id":"F2","agent":"divisor-sre-code","severity":"MEDIUM","file":"b.go","line":4,
  "evidence":"y = 2","description":"d2","recommendation":"r2","verdict":"REQUEST CHANGES",
  "status":"correctable","reason":"EVIDENCE_NOT_FOUND","provenance":{}},
 {"id":"F3","agent":"divisor-sre-code","severity":"LOW","file":"c.go","line":2,
  "evidence":"z := 3","description":"d3","recommendation":"r3","verdict":"REQUEST CHANGES",
  "status":"correctable","reason":"LINE_MISMATCH","provenance":{}},
 {"id":"F4","agent":"divisor-testing-code","severity":"MEDIUM","file":"b.go","line":4,
  "evidence":"y == 2","description":"d4","recommendation":"r4","verdict":"REQUEST CHANGES",
  "status":"correctable","reason":"EVIDENCE_NOT_FOUND","provenance":{}},
 {"id":"F5","agent":"divisor-testing-code","severity":"LOW","file":"a.go","line":3,
  "evidence":"x = 1","description":"d5","recommendation":"r5","verdict":"REQUEST CHANGES",
  "status":"correctable","reason":"EVIDENCE_NOT_FOUND","provenance":{}}],
 "stripped":[],
 "total_findings":5,"duplicates_consolidated":0,"verdicts":{"divisor-guard-code":"REQUEST CHANGES"}}
FJ
}

corrections() { # dir json
	printf '%s\n' "$2" >"$1/session/verdicts/_meta/corrections.json"
}

apply() { # dir
	bash "$SCRIPT" "$1/session" "$1/root"
}

findings() { # dir
	cat "$1/session/verdicts/findings.json"
}

unchanged() { # dir before label
	local now
	now=$(findings "$1")
	if [[ "$now" == "$2" ]]; then
		echo "  PASS: $3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $3 (findings.json changed)"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test 1: a missing session or findings.json is nothing_to_do"
result=$(bash "$SCRIPT" /nonexistent)
assert_json_field "$result" "status" "nothing_to_do" "missing session"
d=$(mktemp -d)
mkdir -p "$d/session/verdicts"
result=$(bash "$SCRIPT" "$d/session" "$d")
assert_json_field "$result" "status" "nothing_to_do" "missing findings.json"
rm -rf "$d"

echo "Test 2: a correction that matches the source is verified under its own id"
d=$(mktemp -d)
mk_session "$d"
corrections "$d" '{"results":[
 {"id":"F2","outcome":"CORRECTED","evidence":"y := 2"},
 {"id":"F3","outcome":"CORRECTED","evidence":"z := 3","line":22},
 {"id":"F4","outcome":"WITHDRAWN"},
 {"id":"F5","outcome":"WITHDRAWN"}]}'
result=$(apply "$d")
assert_json_field "$result" "status" "ok" "status ok"
assert_jq "$d/session/verdicts/findings.json" '[.verified[].id] | sort | join(",")' "F1,F2,F3" "F2 and F3 joined F1 in verified"
assert_jq "$d/session/verdicts/findings.json" '.verified[] | select(.id=="F2") | [.status, .evidence] | join("|")' "verified|y := 2" "F2 carries the corrected quote"
assert_jq "$d/session/verdicts/findings.json" '.verified[] | select(.id=="F2") | has("reason")' "false" "F2 no longer carries a correctable reason"
assert_jq "$d/session/verdicts/findings.json" '.verified[] | select(.id=="F2") | .provenance.correction | [.from.evidence, .reason] | join("|")' "y = 2|EVIDENCE_NOT_FOUND" "F2 records what it was corrected from"
assert_jq "$d/session/verdicts/findings.json" '.verified[] | select(.id=="F3") | .line' "22" "F3 takes the corrected line"
assert_jq "$d/session/verdicts/findings.json" '.correctable | length' "0" "nothing left correctable"
rm -rf "$d"

echo "Test 3: a correction that still does not match is stripped, never verified"
# The integrity check the hand edit skipped: an agent that re-emits a quote the
# file does not contain must not see it promoted.
d=$(mktemp -d)
mk_session "$d"
corrections "$d" '{"results":[
 {"id":"F2","outcome":"CORRECTED","evidence":"y := 99"},
 {"id":"F3","outcome":"CORRECTED","evidence":"z := 3"},
 {"id":"F4","outcome":"WITHDRAWN"},{"id":"F5","outcome":"WITHDRAWN"}]}'
result=$(apply "$d")
assert_json_field "$result" "status" "ok" "status ok"
assert_jq "$d/session/verdicts/findings.json" '.stripped[] | select(.id=="F2") | [.status, .reason] | join("|")' "stripped|CORRECTION_FAILED" "a quote still absent is stripped"
assert_jq "$d/session/verdicts/findings.json" '.stripped[] | select(.id=="F2") | .provenance.correction | [.attempted.evidence, .check] | join("|")' "y := 99|EVIDENCE_NOT_FOUND" "the failed attempt is recorded with the check it failed"
# F3's quote exists but its line (2) was never corrected, so the window check
# still fails: a correction must pass the same test, line included.
assert_jq "$d/session/verdicts/findings.json" '.stripped[] | select(.id=="F3") | .provenance.correction.check' "LINE_MISMATCH" "a quote fixed without its line still fails the window"
assert_jq "$d/session/verdicts/findings.json" '[.verified[].id] | join(",")' "F1" "nothing was promoted"
rm -rf "$d"

echo "Test 4: a withdrawn finding is removed, an unanswered one stripped"
d=$(mktemp -d)
mk_session "$d"
corrections "$d" '{"results":[{"id":"F4","outcome":"WITHDRAWN"}]}'
result=$(apply "$d")
assert_json_field "$result" "status" "ok" "status ok"
assert_jq_str "$result" '.withdrawn | join(",")' "F4" "the withdrawal is reported"
assert_jq "$d/session/verdicts/findings.json" '[.verified[], .correctable[], .stripped[] | select(.id=="F4")] | length' "0" "a withdrawn finding is removed, not stripped"
assert_jq_str "$result" '.unanswered | join(",")' "F2,F3,F5" "unanswered findings are reported"
assert_jq "$d/session/verdicts/findings.json" '[.stripped[] | select(.reason=="NO_CORRECTION") | .id] | join(",")' "F2,F3,F5" "and stripped as NO_CORRECTION"
rm -rf "$d"

echo "Test 5: bad input is refused and findings.json left unchanged"
for body in \
	'not json' \
	'{"results":"nope"}' \
	'{"results":[{"id":"F9","outcome":"WITHDRAWN"}]}' \
	'{"results":[{"id":"F1","outcome":"WITHDRAWN"}]}' \
	'{"results":[{"id":"F2","outcome":"WITHDRAWN"},{"id":"F2","outcome":"WITHDRAWN"}]}' \
	'{"results":[{"id":"F2","outcome":"FIXED"}]}' \
	'{"results":[{"id":"F2","outcome":"CORRECTED"}]}' \
	'{"results":[{"id":"F2","outcome":"CORRECTED","evidence":""}]}' \
	'{"results":[{"id":"F2","outcome":"CORRECTED","evidence":"y := 2","line":0}]}' \
	'{"results":[{"id":"F2","outcome":"CORRECTED","evidence":"y := 2","line":"4"}]}' \
	'{"results":[{"id":"F2","outcome":"CORRECTED","evidence":"y := 2","file":"a.go"}]}'; do
	d=$(mktemp -d)
	mk_session "$d"
	before=$(findings "$d")
	corrections "$d" "$body"
	result=$(apply "$d")
	assert_json_field "$result" "status" "correction_error" "refused: $body"
	unchanged "$d" "$before" "unchanged: $body"
	rm -rf "$d"
done

echo "Test 6: no corrections.json is refused; an empty results list strips all"
# A missing reply is the orchestrator not having recorded the round, not every
# agent declining; stripping four findings for it would be the silent drop.
d=$(mktemp -d)
mk_session "$d"
before=$(findings "$d")
result=$(apply "$d")
assert_json_field "$result" "status" "correction_error" "missing corrections.json refused"
unchanged "$d" "$before" "findings.json unchanged"
corrections "$d" '{"results":[]}'
result=$(apply "$d")
assert_json_field "$result" "status" "ok" "an explicit empty round applies"
assert_jq "$d/session/verdicts/findings.json" '[.stripped[].reason] | unique | join(",")' "NO_CORRECTION" "every finding stripped as unanswered"
rm -rf "$d"

echo "Test 7: a correction that duplicates a verified finding is merged"
d=$(mktemp -d)
mk_session "$d"
corrections "$d" '{"results":[
 {"id":"F5","outcome":"CORRECTED","evidence":"x := 1"},
 {"id":"F2","outcome":"WITHDRAWN"},{"id":"F3","outcome":"WITHDRAWN"},{"id":"F4","outcome":"WITHDRAWN"}]}'
result=$(apply "$d")
assert_jq "$d/session/verdicts/findings.json" '[.verified[].id] | join(",")' "F1" "F5 merged into F1, the more severe"
assert_jq "$d/session/verdicts/findings.json" '.duplicates_consolidated' "1" "the merge is counted"
assert_jq "$d/session/verdicts/findings.json" '.verified[0].provenance.consolidated_from[0].agent' "divisor-testing-code" "F5's reviewer is credited"
rm -rf "$d"

echo "Test 8: a second run on its own output changes nothing"
d=$(mktemp -d)
mk_session "$d"
corrections "$d" '{"results":[{"id":"F2","outcome":"CORRECTED","evidence":"y := 2"}]}'
apply "$d" >/dev/null
after=$(findings "$d")
result=$(apply "$d")
assert_json_field "$result" "status" "nothing_to_do" "no correctable findings left"
unchanged "$d" "$after" "findings.json unchanged on re-run"
rm -rf "$d"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
