#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JQ_DIR="$SCRIPT_DIR/../skills/review-council/scripts/jq"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# The two reducers below carry the pipeline's only two silent-data-loss paths:
# RC-1 deleted every finding outside the cluster being reduced, and RC-20
# dropped a second reviewer's angle on an exact duplicate. Both survived for as
# long as they did because reaching them meant building a session directory and
# running a shell script over it, so no test ever addressed the transformation
# on its own. Driven directly from fixture JSON, each is a pure function from
# input to output and the interesting cases cost three lines apiece.

# Run a jq program over an inline JSON document. Extra args (--argjson ...) are
# forwarded. Usage: run_jq <program.jq> <input-json> [jq args...]
run_jq() {
	local prog="$1" input="$2"
	shift 2
	printf '%s' "$input" | jq -c "$@" -f "$JQ_DIR/$prog"
}

# ---------------------------------------------------------------------------
echo "Test 1: dedup keeps findings that are not duplicates of each other"
# The conservation case RC-1's sibling bug needed: bystanders in the input, so
# a reducer that over-deletes cannot pass by accident.
input='[
 {"file":"a.go","line":1,"evidence":"e1","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"b.go","line":9,"evidence":"e2","severity":"HIGH","agent":"y","description":"d2","recommendation":"r2"},
 {"file":"c.go","line":4,"evidence":"e3","severity":"LOW","agent":"z","description":"d3","recommendation":"r3"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "3" "three distinct findings all survive"
assert_jq_str "$out" '[.[].file] | join(",")' "a.go,b.go,c.go" "order and identity preserved"

echo "Test 2: same file, same evidence, line within +-5 merges"
input='[
 {"file":"a.go","line":10,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":14,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "1" "within the window, merged"

echo "Test 3: the same evidence beyond the +-5 window is left alone"
# The window is the whole reason a citation can be slightly off and still
# verify; widening it silently would merge unrelated findings.
input='[
 {"file":"a.go","line":10,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":16,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "2" "outside the window, kept separate"

echo "Test 4: two null lines merge, a null and a number do not"
input='[
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "1" "both null merges"
input='[
 {"file":"a.go","line":null,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":3,"evidence":"e","severity":"LOW","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" 'length' "2" "null vs number stays separate"

echo "Test 5: the merged survivor keeps the highest severity, whatever the order"
# Order independence matters because agent dispatch order is not fixed: the
# same review must not produce a HIGH on one run and a LOW on the next.
low_first='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"y","description":"d2","recommendation":"r2"}
]'
high_first='[
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"y","description":"d2","recommendation":"r2"},
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"d1","recommendation":"r1"}
]'
out=$(run_jq dedup-findings.jq "$low_first")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "low first — max severity kept"
out=$(run_jq dedup-findings.jq "$high_first")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "high first — max severity kept"

echo "Test 6: an unknown severity ranks below every known one"
# sevrank returns 0 for anything unlisted. A typo'd severity must never
# outrank a real CRITICAL and silently downgrade it.
input='[
 {"file":"a.go","line":1,"evidence":"e","severity":"CRITICAL","agent":"x","description":"d1","recommendation":"r1"},
 {"file":"a.go","line":1,"evidence":"e","severity":"SEVERE","agent":"y","description":"d2","recommendation":"r2"}
]'
out=$(run_jq dedup-findings.jq "$input")
assert_jq_str "$out" '.[0].severity' "CRITICAL" "unknown severity does not displace CRITICAL"

echo "Test 7: a cross-agent duplicate is credited, a self-duplicate is not"
cross='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"boundary","recommendation":"use <="},
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"y","description":"untested","recommendation":"add a case"}
]'
out=$(run_jq dedup-findings.jq "$cross")
assert_jq_str "$out" '.[0].provenance.consolidated_from | length' "1" "cross-agent duplicate credited"
assert_jq_str "$out" '.[0].provenance.consolidated_from[0].agent' "y" "credit names the other agent"
assert_jq_str "$out" '.[0].provenance.consolidated_from[0].angle' "untested" "credit carries the angle"
self='[
 {"file":"a.go","line":1,"evidence":"e","severity":"LOW","agent":"x","description":"first","recommendation":"r"},
 {"file":"a.go","line":1,"evidence":"e","severity":"HIGH","agent":"x","description":"second","recommendation":"r"}
]'
out=$(run_jq dedup-findings.jq "$self")
assert_jq_str "$out" '(.[0].provenance.consolidated_from // []) | length' "0" "self-duplicate not credited"
assert_jq_str "$out" '.[0].severity' "HIGH" "self-duplicate still escalates severity"

echo "Test 8: an empty input yields an empty array, not null"
out=$(run_jq dedup-findings.jq '[]')
assert_equals "$out" "[]" "empty in, empty out"

# ---------------------------------------------------------------------------
echo "Test 9: consolidation merges a cluster and conserves every bystander"
# RC-1 in one assertion: the input carries findings outside the cluster, and a
# reducer scoped wrongly deletes them while still reporting success.
findings='{"verified":[
 {"file":"a.go","line":1,"agent":"x","severity":"MEDIUM","evidence":"e1","description":"d1","recommendation":"r1","verdict":"APPROVE"},
 {"file":"a.go","line":1,"agent":"y","severity":"LOW","evidence":"e2","description":"d2","recommendation":"r2","verdict":"APPROVE"},
 {"file":"b.go","line":9,"agent":"z","severity":"HIGH","evidence":"e3","description":"d3","recommendation":"r3","verdict":"APPROVE"},
 {"file":"c.go","line":4,"agent":"w","severity":"LOW","evidence":"e4","description":"d4","recommendation":"r4","verdict":"APPROVE"}
],"correctable":[],"stripped":[],"total_findings":4,"duplicates_consolidated":0,
 "verdicts":{"x":"APPROVE","y":"APPROVE","z":"APPROVE","w":"APPROVE"}}'
clusters='[{"members":[{"file":"a.go","line":1,"agent":"x"},{"file":"a.go","line":1,"agent":"y"}]}]'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters")
assert_jq_str "$out" '.verified | length' "3" "one cluster of two collapses to one, bystanders kept"
assert_jq_str "$out" '[.verified[].file] | join(",")' "a.go,b.go,c.go" "the surviving files are the right ones"
assert_jq_str "$out" '.duplicates_consolidated' "1" "one semantic duplicate counted"
assert_jq_str "$out" '.consolidation_records | length' "1" "one consolidation record written"

echo "Test 10: the cluster primary is the most severe member"
assert_jq_str "$out" '.verified[0].severity' "MEDIUM" "MEDIUM outranks LOW as primary"
assert_jq_str "$out" '.verified[0].provenance.consolidated_from[0].agent' "y" "the folded member is credited"

echo "Test 11: REQUEST CHANGES anywhere in a cluster wins the merged verdict"
# An APPROVE primary must not launder a REQUEST CHANGES filed by a member it
# absorbed.
findings='{"verified":[
 {"file":"a.go","line":1,"agent":"x","severity":"HIGH","evidence":"e1","description":"d1","recommendation":"r1","verdict":"APPROVE"},
 {"file":"a.go","line":1,"agent":"y","severity":"LOW","evidence":"e2","description":"d2","recommendation":"r2","verdict":"REQUEST CHANGES"}
],"correctable":[],"stripped":[],"total_findings":2,"duplicates_consolidated":0,"verdicts":{}}'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters")
assert_jq_str "$out" '.verified[0].verdict' "REQUEST CHANGES" "REQUEST CHANGES wins over the primary's APPROVE"

echo "Test 12: a cluster naming fewer than two present members is a no-op"
# A manifest can name a member that verification stripped. Merging a
# single-member 'cluster' would rewrite a finding for no reason.
clusters_one='[{"members":[{"file":"a.go","line":1,"agent":"x"},{"file":"gone.go","line":7,"agent":"absent"}]}]'
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters "$clusters_one")
assert_jq_str "$out" '.verified | length' "2" "nothing merged"
assert_jq_str "$out" '.duplicates_consolidated' "0" "nothing counted"
assert_jq_str "$out" '.consolidation_records | length' "0" "no record written"

echo "Test 13: an empty cluster list leaves the document untouched"
out=$(run_jq consolidate-clusters.jq "$findings" --argjson clusters '[]')
assert_jq_str "$out" '.verified | length' "2" "both findings survive"
assert_jq_str "$out" '.duplicates_consolidated' "0" "count unchanged"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
