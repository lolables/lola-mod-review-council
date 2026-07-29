#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-consolidate.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Write a findings.json with the given verified array into a session.
mk_session() { # verified_json
	local s
	s=$(mktemp -d)
	mkdir -p "$s/verdicts"
	jq -n --argjson v "$1" '{verified:$v, correctable:[], stripped:[],
		total_findings:($v|length), duplicates_consolidated:0,
		verdicts:{}}' >"$s/verdicts/findings.json"
	echo "$s"
}

echo "Test 1: missing session -> nothing_to_do"
result=$(bash "$SCRIPT" "/nonexistent" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "missing session"

echo "Test 2: no manifest -> findings unchanged, ok"
s=$(mk_session '[{"agent":"a","severity":"HIGH","file":"f.go","line":1,"evidence":"e","description":"d","recommendation":"r","verdict":"REQUEST CHANGES","status":"verified","provenance":{}}]')
before=$(cat "$s/verdicts/findings.json")
result=$(bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "no manifest ok"
after=$(cat "$s/verdicts/findings.json")
if [[ "$before" == "$after" ]]; then
	echo "  PASS: findings unchanged"
	PASS=$((PASS + 1))
else
	echo "  FAIL: findings mutated"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 3: empty clusters -> no-op"
s=$(mk_session '[{"agent":"a","severity":"HIGH","file":"f.go","line":1,"evidence":"e","description":"d","recommendation":"r","verdict":"REQUEST CHANGES","status":"verified","provenance":{}}]')
echo '{"clusters":[]}' >"$s/verdicts/clusters.json"
result=$(bash "$SCRIPT" "$s")
dc=$(jq '.duplicates_consolidated' "$s/verdicts/findings.json")
if [[ "$dc" -eq 0 ]]; then
	echo "  PASS: count stays 0"
	PASS=$((PASS + 1))
else
	echo "  FAIL: dc=$dc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 4: three same-defect findings -> one primary, two folded"
s=$(mk_session '[
  {"agent":"divisor-adversary-code","severity":"MEDIUM","file":"svc/load.py","line":42,"evidence":"except:","description":"CWE-390 swallow","recommendation":"catch specific","verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
  {"agent":"divisor-testing-code","severity":"HIGH","file":"svc/load.py","line":42,"evidence":"except:","description":"untested failure path","recommendation":"add a test","verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
  {"agent":"divisor-sre-code","severity":"LOW","file":"svc/load.py","line":44,"evidence":"except:","description":"observability gap","recommendation":"log the error","verdict":"APPROVE","status":"verified","provenance":{}}
]')
cat >"$s/verdicts/clusters.json" <<'CJ'
{"clusters":[{"members":[
  {"file":"svc/load.py","line":42,"agent":"divisor-adversary-code"},
  {"file":"svc/load.py","line":42,"agent":"divisor-testing-code"},
  {"file":"svc/load.py","line":44,"agent":"divisor-sre-code"}
]}]}
CJ
bash "$SCRIPT" "$s" >/dev/null
fj="$s/verdicts/findings.json"
vlen=$(jq '.verified | length' "$fj")
if [[ "$vlen" -eq 1 ]]; then
	echo "  PASS: collapsed to 1 verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vlen"
	FAIL=$((FAIL + 1))
fi
prim_sev=$(jq -r '.verified[0].severity' "$fj")
if [[ "$prim_sev" == "HIGH" ]]; then
	echo "  PASS: primary is highest severity"
	PASS=$((PASS + 1))
else
	echo "  FAIL: sev=$prim_sev"
	FAIL=$((FAIL + 1))
fi
folded=$(jq '.verified[0].provenance.consolidated_from | length' "$fj")
if [[ "$folded" -eq 2 ]]; then
	echo "  PASS: two angles folded"
	PASS=$((PASS + 1))
else
	echo "  FAIL: folded=$folded"
	FAIL=$((FAIL + 1))
fi
dc=$(jq '.duplicates_consolidated' "$fj")
if [[ "$dc" -eq 2 ]]; then
	echo "  PASS: count=2"
	PASS=$((PASS + 1))
else
	echo "  FAIL: dc=$dc"
	FAIL=$((FAIL + 1))
fi
recs=$(jq '.consolidation_records | length' "$fj")
if [[ "$recs" -eq 1 ]]; then
	echo "  PASS: one record"
	PASS=$((PASS + 1))
else
	echo "  FAIL: recs=$recs"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 5: verdict preserved when a member is REQUEST CHANGES"
s=$(mk_session '[
  {"agent":"a","severity":"HIGH","file":"x.go","line":10,"evidence":"boom","description":"da","recommendation":"ra","verdict":"APPROVE","status":"verified","provenance":{}},
  {"agent":"b","severity":"LOW","file":"x.go","line":10,"evidence":"boom","description":"db","recommendation":"rb","verdict":"REQUEST CHANGES","status":"verified","provenance":{}}
]')
cat >"$s/verdicts/clusters.json" <<'CJ'
{"clusters":[{"members":[{"file":"x.go","line":10,"agent":"a"},{"file":"x.go","line":10,"agent":"b"}]}]}
CJ
bash "$SCRIPT" "$s" >/dev/null
pv=$(jq -r '.verified[0].verdict' "$s/verdicts/findings.json")
if [[ "$pv" == "REQUEST CHANGES" ]]; then
	echo "  PASS: verdict preserved"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict=$pv"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo "Test 6: idempotent — second run changes nothing"
s=$(mk_session '[
  {"agent":"a","severity":"HIGH","file":"x.go","line":10,"evidence":"boom","description":"da","recommendation":"ra","verdict":"REQUEST CHANGES","status":"verified","provenance":{}},
  {"agent":"b","severity":"LOW","file":"x.go","line":10,"evidence":"boom","description":"db","recommendation":"rb","verdict":"APPROVE","status":"verified","provenance":{}}
]')
cat >"$s/verdicts/clusters.json" <<'CJ'
{"clusters":[{"members":[{"file":"x.go","line":10,"agent":"a"},{"file":"x.go","line":10,"agent":"b"}]}]}
CJ
bash "$SCRIPT" "$s" >/dev/null
first=$(cat "$s/verdicts/findings.json")
bash "$SCRIPT" "$s" >/dev/null
second=$(cat "$s/verdicts/findings.json")
if [[ "$first" == "$second" ]]; then
	echo "  PASS: idempotent"
	PASS=$((PASS + 1))
else
	echo "  FAIL: second run differs"
	FAIL=$((FAIL + 1))
fi
dc=$(echo "$second" | jq '.duplicates_consolidated')
if [[ "$dc" -eq 1 ]]; then
	echo "  PASS: count not double-added"
	PASS=$((PASS + 1))
else
	echo "  FAIL: dc=$dc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
