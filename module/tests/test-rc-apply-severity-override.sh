#!/usr/bin/env bash
# rc-apply-severity-override.sh: the project's Severity override applied to
# verified findings (#121).
#
# A severity pack can only ask reviewers and the arbiter to rate differently.
# The override is the deterministic knob: tracking.md carries the normalised
# terms rc-prepare.sh parsed from the base revision, and this script moves each
# matching finding inside its bound before verdicts are recomputed and decided.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$SCRIPT_DIR/../skills/review-council/scripts"
SCRIPT="$SCRIPTS/rc-apply-severity-override.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# One finding per case the rules distinguish:
#   F1 guard code HIGH, with an impact      F2 guard spec CRITICAL, prior calibration
#   F3 sre code LOW, no impact              F4 testing code MEDIUM, credits a guard HIGH
#   F5 adversary HIGH marked SCRIPT          F6 curator code MEDIUM
# F5 carries a persona's name on purpose: verify.md says the SCRIPT mark, not
# the agent name, identifies a script finding, so the mark alone must protect it.
mk_session() { # override
	local s
	s=$(new_session)
	printf '## Phase: Preparation\n\n- Severity override: %s\n\n' "$1" >"$s/tracking.md"
	cat >"$s/verdicts/findings.json" <<'FJ'
{"verified":[
 {"id":"F1","agent":"divisor-guard-code","severity":"HIGH","file":"a.go","line":3,"evidence":"x","description":"d1",
  "recommendation":"r1","impact":"Callers of A break.","verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
 {"id":"F2","agent":"divisor-guard-spec","severity":"CRITICAL","file":"spec.md","line":1,"evidence":"y","description":"d2",
  "recommendation":"r2","impact":"Implementers drift.","verdict":"REQUEST CHANGES","status":"verified",
  "provenance":{"calibrated_from":[{"from":"HIGH","to":"CRITICAL","reason":"arbiter: names a consequence"}]}},
 {"id":"F3","agent":"divisor-sre-code","severity":"LOW","file":"b.go","line":2,"evidence":"z","description":"d3",
  "recommendation":"r3","verdict":"APPROVE","status":"verified","provenance":{}},
 {"id":"F4","agent":"divisor-testing-code","severity":"MEDIUM","file":"c_test.go","line":4,"evidence":"t","description":"d4",
  "recommendation":"r4","verdict":"REQUEST CHANGES","status":"verified",
  "provenance":{"consolidated_from":[{"agent":"divisor-guard-code","severity":"HIGH","file":"c_test.go","line":4}]}},
 {"id":"F5","agent":"divisor-adversary-code","severity":"HIGH","file":"run.sh","line":1,"evidence":"ln","description":"d5",
  "recommendation":"r5","impact":"Reads outside the tree.","verdict":"REQUEST CHANGES","status":"verified",
  "provenance":{"validator":{"result":"SCRIPT","reason":"computed from the diff"}}},
 {"id":"F6","agent":"divisor-curator-code","severity":"MEDIUM","file":"README.md","line":9,"evidence":"r","description":"d6",
  "recommendation":"r6","verdict":"APPROVE","status":"verified","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":6,"duplicates_consolidated":1,"verdicts":{}}
FJ
	printf '%s' "$s"
}

sev() { # session id
	jq -r --arg id "$2" '.verified[] | select(.id == $id) | .severity' "$1/verdicts/findings.json"
}

echo "Test 1: a cap lowers every finding of the persona above it, -code and -spec alike"
s=$(mk_session "guard<=LOW")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "status ok"
got=$(sev "$s" F1)
assert_equals "$got" "LOW" "guard code HIGH capped to LOW"
got=$(sev "$s" F2)
assert_equals "$got" "LOW" "guard spec CRITICAL capped to LOW"
got=$(sev "$s" F6)
assert_equals "$got" "MEDIUM" "another persona is untouched"
assert_jq_str "$result" '[.changes[] | .id] | sort | join(",")' "F1,F2" "changes list exactly the capped findings"
assert_jq_str "$result" '.changes[] | select(.id == "F1") | "\(.agent) \(.from) \(.to) \(.term)"' \
	"divisor-guard-code HIGH LOW guard<=LOW" "a change names agent, levels and term"
rm -rf "$s"

echo "Test 2: a cap leaves findings already within it alone"
s=$(mk_session "curator<=HIGH")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "status ok"
assert_jq_str "$result" '.changes | length' "0" "nothing changes"
got=$(sev "$s" F6)
assert_equals "$got" "MEDIUM" "curator MEDIUM stays"
rm -rf "$s"

echo "Test 3: a floor raises findings below it, and fills a missing impact"
s=$(mk_session "sre>=HIGH")
bash "$SCRIPT" "$s" >/dev/null
got=$(sev "$s" F3)
assert_equals "$got" "HIGH" "sre LOW floored to HIGH"
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F3") | .impact' \
	"Raised by project configuration (Severity override: sre>=HIGH)." "a raised finding gets an impact"
rm -rf "$s"

echo "Test 4: a floor never lowers, and an existing impact is kept"
s=$(mk_session "guard>=HIGH")
result=$(bash "$SCRIPT" "$s")
got=$(sev "$s" F2)
assert_equals "$got" "CRITICAL" "a CRITICAL above the floor stays CRITICAL"
assert_jq_str "$result" '.changes | length' "0" "nothing changes"
s2=$(mk_session "curator>=HIGH")
bash "$SCRIPT" "$s2" >/dev/null
assert_jq "$s2/verdicts/findings.json" '.verified[] | select(.id == "F6") | .impact' \
	"Raised by project configuration (Severity override: curator>=HIGH)." "MEDIUM raised to HIGH gets an impact"
rm -rf "$s" "$s2"
s=$(mk_session "guard=CRITICAL")
bash "$SCRIPT" "$s" >/dev/null
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F1") | .impact' \
	"Callers of A break." "an impact the reviewer wrote is never replaced"
rm -rf "$s"

echo "Test 5: set moves both directions"
s=$(mk_session "guard=MEDIUM, sre=MEDIUM")
bash "$SCRIPT" "$s" >/dev/null
got=$(sev "$s" F1)
assert_equals "$got" "MEDIUM" "HIGH set to MEDIUM"
got=$(sev "$s" F3)
assert_equals "$got" "MEDIUM" "LOW set to MEDIUM"
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F3") | has("impact")' \
	"false" "a finding raised to MEDIUM gets no impact: only blocking findings need one"
rm -rf "$s"

echo "Test 6: each change is appended to provenance.calibrated_from"
s=$(mk_session "guard<=MEDIUM")
bash "$SCRIPT" "$s" >/dev/null
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F2") | .provenance.calibrated_from | length' \
	"2" "the arbiter's entry is kept and one is appended"
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F2") | .provenance.calibrated_from[1] | "\(.from) \(.to) \(.reason)"' \
	"CRITICAL MEDIUM config: Severity override guard<=MEDIUM" "the appended entry records levels and the term"
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F1") | .provenance.calibrated_from | length' \
	"1" "a finding with no prior record gets one"
rm -rf "$s"

echo "Test 7: a script finding is never changed, though its agent names a persona"
s=$(mk_session "adversary<=LOW")
result=$(bash "$SCRIPT" "$s")
got=$(sev "$s" F5)
assert_equals "$got" "HIGH" "the SCRIPT-marked finding keeps its level"
assert_jq_str "$result" '.changes | length' "0" "nothing is reported changed"
rm -rf "$s"

echo "Test 8: credits keep the level each reviewer filed"
s=$(mk_session "guard<=LOW, testing>=HIGH")
bash "$SCRIPT" "$s" >/dev/null
got=$(sev "$s" F4)
assert_equals "$got" "HIGH" "the finding follows its own agent's term"
assert_jq "$s/verdicts/findings.json" '.verified[] | select(.id == "F4") | .provenance.consolidated_from[0].severity' \
	"HIGH" "the guard's credit is untouched by the guard cap"
rm -rf "$s"

echo "Test 9: no override, or none, is nothing_to_do and writes nothing"
s=$(mk_session "none")
before=$(cat "$s/verdicts/findings.json")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "nothing_to_do" "none -> nothing_to_do"
after=$(cat "$s/verdicts/findings.json")
assert_equals "$after" "$before" "findings.json is unchanged"
printf '## Phase: Preparation\n\n- Effort: standard\n' >"$s/tracking.md"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "nothing_to_do" "a session prepared before the key existed -> nothing_to_do"
rm -rf "$s"
result=$(bash "$SCRIPT" /nonexistent)
assert_json_field "$result" "status" "nothing_to_do" "missing session -> nothing_to_do"
s=$(mk_session "guard<=LOW")
rm -f "$s/verdicts/findings.json"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "nothing_to_do" "missing findings.json -> nothing_to_do"
rm -rf "$s"

echo "Test 10: an unreadable findings.json is a validation_error and is not written"
s=$(mk_session "guard<=LOW")
printf 'not json\n' >"$s/verdicts/findings.json"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "unparsable -> validation_error"
after=$(cat "$s/verdicts/findings.json")
assert_equals "$after" "not json" "the file is left as it was"
jq '.verified[0].severity = "SEVERE"' <<<'{"verified":[{"id":"F1","agent":"divisor-guard-code","severity":"HIGH","provenance":{}}]}' \
	>"$s/verdicts/findings.json"
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "an unknown severity -> validation_error"
jq -n '{verified:[{id:"F1",agent:"divisor-guard-code",severity:"HIGH",provenance:{calibrated_from:"HIGH"}}]}' \
	>"$s/verdicts/findings.json"
before=$(cat "$s/verdicts/findings.json")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "validation_error" "a string calibrated_from -> validation_error"
after=$(cat "$s/verdicts/findings.json")
assert_equals "$after" "$before" "the file is left as it was"
rm -rf "$s"

echo "Test 11: a tracking line not in the normalised form is a validation_error"
for bad in "guard <= LOW" "guard<=low" "wizard<=LOW" "guard<=LOW, guard>=HIGH" "guard<=LOW,,sre>=HIGH"; do
	s=$(mk_session "$bad")
	before=$(cat "$s/verdicts/findings.json")
	result=$(bash "$SCRIPT" "$s")
	assert_json_field "$result" "status" "validation_error" "'$bad' -> validation_error"
	after=$(cat "$s/verdicts/findings.json")
	assert_equals "$after" "$before" "'$bad' leaves findings.json unchanged"
	rm -rf "$s"
done

echo "Test 12: an extra argument is a validation_error"
s=$(mk_session "guard<=LOW")
result=$(bash "$SCRIPT" "$s" --final)
assert_json_field "$result" "status" "validation_error" "unknown argument refused"
rm -rf "$s"

echo "Test 13: end to end, guard<=LOW takes the council from REQUEST CHANGES to APPROVE WITH ADVISORIES"
# One Guard HIGH and one Curator MEDIUM: blocking only because of the Guard.
e2e_session() { # override
	local s
	s=$(new_session)
	printf '## Phase: Preparation\n\n- Severity override: %s\n\n' "$1" >"$s/tracking.md"
	cat >"$s/verdicts/findings.json" <<'FJ'
{"verified":[
 {"id":"F1","agent":"divisor-guard-code","severity":"HIGH","file":"a.go","line":3,"evidence":"x","description":"d",
  "recommendation":"r","impact":"i","verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
 {"id":"F2","agent":"divisor-curator-code","severity":"MEDIUM","file":"README.md","line":1,"evidence":"y","description":"d",
  "recommendation":"r","verdict":"APPROVE","status":"verified","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":2,"duplicates_consolidated":0,"verdicts":{}}
FJ
	printf '{"divisor-guard-code":"REQUEST CHANGES","divisor-curator-code":"APPROVE"}\n' >"$s/verdicts/verdicts-map.json"
	printf '%s' "$s"
}
for case_ in "none|REQUEST CHANGES" "guard<=LOW|APPROVE WITH ADVISORIES"; do
	override="${case_%%|*}"
	want="${case_#*|}"
	s=$(e2e_session "$override")
	bash "$SCRIPT" "$s" >/dev/null
	bash "$SCRIPTS/rc-recompute-verdicts.sh" "$s" >/dev/null
	bash "$SCRIPTS/rc-decide-verdict.sh" "$s" >/dev/null
	got=$(cat "$s/verdict.txt")
	assert_equals "$got" "$want" "override '$override' -> $want"
	rm -rf "$s"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
