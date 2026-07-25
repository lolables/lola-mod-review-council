#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$SCRIPT_DIR/../skills/review-council/scripts/rc-extract-verdict.sh"
VERIFY="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"
source "$SCRIPT_DIR/test-helpers.sh"

# Regression guard: --effort deep writes reviewer output to nested
# verdicts/{subsystem}/{agent}.raw.md (see phases/delegate.md). The JSON
# pipeline must recurse into subsystem subdirectories, not just the flat
# top-level layout used by standard/quick mode.

echo "Test 1: extract deep — two subsystems, same agent name, no clobber"
s=$(mktemp -d); mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
cat >"$s/verdicts/auth/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["auth/token.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"auth/token.go","line":1,"evidence":"if exp < now","description":"boundary bug","recommendation":"use <="}]}
```
RAW
cat >"$s/verdicts/api/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["api/handler.go"],"verdict":"APPROVE","findings":[]}
```
RAW
result=$(bash "$EXTRACT" "$s")
assert_json_field "$result" "status" "ok" "extract deep status ok"
[[ -f "$s/verdicts/auth/divisor-adversary-code.json" ]] && { echo "  PASS: auth json written"; PASS=$((PASS+1)); } || { echo "  FAIL: no auth json"; FAIL=$((FAIL+1)); }
[[ -f "$s/verdicts/api/divisor-adversary-code.json" ]] && { echo "  PASS: api json written"; PASS=$((PASS+1)); } || { echo "  FAIL: no api json"; FAIL=$((FAIL+1)); }
av=$(jq -r '.verdict' "$s/verdicts/auth/divisor-adversary-code.json" 2>/dev/null || echo MISSING)
[[ "$av" == "REQUEST CHANGES" ]] && { echo "  PASS: auth verdict not clobbered"; PASS=$((PASS+1)); } || { echo "  FAIL: auth verdict '$av'"; FAIL=$((FAIL+1)); }
pv=$(jq -r '.verdict' "$s/verdicts/api/divisor-adversary-code.json" 2>/dev/null || echo MISSING)
[[ "$pv" == "APPROVE" ]] && { echo "  PASS: api verdict not clobbered"; PASS=$((PASS+1)); } || { echo "  FAIL: api verdict '$pv'"; FAIL=$((FAIL+1)); }

echo "Test 2: verify deep — findings from both subsystems present"
src=$(mktemp -d); mkdir -p "$src/auth" "$src/api"
echo 'if exp < now' >"$src/auth/token.go"
echo 'package api' >"$src/api/handler.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verify deep status ok"
total=$(jq -r '.total_findings' "$s/verdicts/findings.json")
[[ "$total" -eq 1 ]] && { echo "  PASS: total_findings 1 (auth finding + api's empty findings)"; PASS=$((PASS+1)); } || { echo "  FAIL: total_findings $total"; FAIL=$((FAIL+1)); }
vfile=$(jq -r '.verified[0].file' "$s/verdicts/findings.json")
[[ "$vfile" == "auth/token.go" ]] && { echo "  PASS: auth finding verified"; PASS=$((PASS+1)); } || { echo "  FAIL: verified file '$vfile'"; FAIL=$((FAIL+1)); }
rm -rf "$s" "$src"

echo "Test 3: verdict aggregation — REQUEST CHANGES wins over APPROVE"
s=$(mktemp -d); mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
cat >"$s/verdicts/auth/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":[],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"HIGH","file":"auth/token.go","line":1,"evidence":"if exp < now","description":"d","recommendation":"r"}]}
```
RAW
cat >"$s/verdicts/api/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":[],"verdict":"APPROVE","findings":[]}
```
RAW
bash "$EXTRACT" "$s" >/dev/null
src=$(mktemp -d); mkdir -p "$src/auth"; echo 'if exp < now' >"$src/auth/token.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verdict aggregation status ok"
agg=$(jq -r '.verdicts."divisor-adversary-code"' "$s/verdicts/findings.json")
[[ "$agg" == "REQUEST CHANGES" ]] && { echo "  PASS: REQUEST CHANGES wins"; PASS=$((PASS+1)); } || { echo "  FAIL: aggregated verdict '$agg'"; FAIL=$((FAIL+1)); }
rm -rf "$s" "$src"

echo "Test 4: verdict aggregation — all APPROVE stays APPROVE"
s=$(mktemp -d); mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
cat >"$s/verdicts/auth/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE","findings":[]}
```
RAW
cat >"$s/verdicts/api/divisor-guard-code.raw.md" <<'RAW'
```json
{"agent":"divisor-guard-code","files_read":[],"verdict":"APPROVE","findings":[]}
```
RAW
bash "$EXTRACT" "$s" >/dev/null
src=$(mktemp -d)
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "all-approve status ok"
agg=$(jq -r '.verdicts."divisor-guard-code"' "$s/verdicts/findings.json")
[[ "$agg" == "APPROVE" ]] && { echo "  PASS: all APPROVE stays APPROVE"; PASS=$((PASS+1)); } || { echo "  FAIL: aggregated verdict '$agg'"; FAIL=$((FAIL+1)); }
rm -rf "$s" "$src"

echo "Test 5: flat mode unchanged — top-level raw.md still extracts and verifies"
s=$(mktemp -d); mkdir -p "$s/verdicts"
cat >"$s/verdicts/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["a.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"MEDIUM","file":"a.go","line":1,"evidence":"x := 1","description":"d","recommendation":"r"}]}
```
RAW
result=$(bash "$EXTRACT" "$s")
assert_json_field "$result" "status" "ok" "flat extract status ok"
[[ -f "$s/verdicts/divisor-adversary-code.json" ]] && { echo "  PASS: flat json written at top level"; PASS=$((PASS+1)); } || { echo "  FAIL: no flat json"; FAIL=$((FAIL+1)); }
src=$(mktemp -d); echo 'x := 1' >"$src/a.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "flat verify status ok"
vc=$(echo "$result" | jq '.verified'); [[ "$vc" -eq 1 ]] && { echo "  PASS: flat finding verified"; PASS=$((PASS+1)); } || { echo "  FAIL: verified $vc"; FAIL=$((FAIL+1)); }
rm -rf "$s" "$src"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
