#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRACT="$SCRIPT_DIR/../skills/review-council/scripts/rc-extract-verdict.sh"
VERIFY="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Regression guard: --effort deep writes reviewer output to nested
# verdicts/{subsystem}/{agent}.raw.md (see phases/delegate.md). The JSON
# pipeline must recurse into subsystem subdirectories, not just the flat
# top-level layout used by standard/quick mode.

echo "Test 1: extract deep — two subsystems, same agent name, no clobber"
s=$(mktemp -d)
mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
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
if [[ -f "$s/verdicts/auth/divisor-adversary-code.json" ]]; then
	echo "  PASS: auth json written"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no auth json"
	FAIL=$((FAIL + 1))
fi
if [[ -f "$s/verdicts/api/divisor-adversary-code.json" ]]; then
	echo "  PASS: api json written"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no api json"
	FAIL=$((FAIL + 1))
fi
av=$(jq -r '.verdict' "$s/verdicts/auth/divisor-adversary-code.json" 2>/dev/null || echo MISSING)
if [[ "$av" == "REQUEST CHANGES" ]]; then
	echo "  PASS: auth verdict not clobbered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: auth verdict '$av'"
	FAIL=$((FAIL + 1))
fi
pv=$(jq -r '.verdict' "$s/verdicts/api/divisor-adversary-code.json" 2>/dev/null || echo MISSING)
if [[ "$pv" == "APPROVE" ]]; then
	echo "  PASS: api verdict not clobbered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: api verdict '$pv'"
	FAIL=$((FAIL + 1))
fi

echo "Test 2: verify deep — findings from both subsystems present"
src=$(mktemp -d)
mkdir -p "$src/auth" "$src/api"
echo 'if exp < now' >"$src/auth/token.go"
echo 'package api' >"$src/api/handler.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verify deep status ok"
total=$(jq -r '.total_findings' "$s/verdicts/findings.json")
if [[ "$total" -eq 1 ]]; then
	echo "  PASS: total_findings 1 (auth finding + api's empty findings)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: total_findings $total"
	FAIL=$((FAIL + 1))
fi
vfile=$(jq -r '.verified[0].file' "$s/verdicts/findings.json")
if [[ "$vfile" == "auth/token.go" ]]; then
	echo "  PASS: auth finding verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified file '$vfile'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 3: verdict aggregation — REQUEST CHANGES wins over APPROVE"
s=$(mktemp -d)
mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
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
src=$(mktemp -d)
mkdir -p "$src/auth"
echo 'if exp < now' >"$src/auth/token.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "verdict aggregation status ok"
agg=$(jq -r '.verdicts."divisor-adversary-code"' "$s/verdicts/findings.json")
if [[ "$agg" == "REQUEST CHANGES" ]]; then
	echo "  PASS: REQUEST CHANGES wins"
	PASS=$((PASS + 1))
else
	echo "  FAIL: aggregated verdict '$agg'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 4: verdict aggregation — all APPROVE stays APPROVE"
s=$(mktemp -d)
mkdir -p "$s/verdicts/auth" "$s/verdicts/api"
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
if [[ "$agg" == "APPROVE" ]]; then
	echo "  PASS: all APPROVE stays APPROVE"
	PASS=$((PASS + 1))
else
	echo "  FAIL: aggregated verdict '$agg'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 5: flat mode unchanged — top-level raw.md still extracts and verifies"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
cat >"$s/verdicts/divisor-adversary-code.raw.md" <<'RAW'
```json
{"agent":"divisor-adversary-code","files_read":["a.go"],"verdict":"REQUEST CHANGES",
 "findings":[{"severity":"MEDIUM","file":"a.go","line":1,"evidence":"x := 1","description":"d","recommendation":"r"}]}
```
RAW
result=$(bash "$EXTRACT" "$s")
assert_json_field "$result" "status" "ok" "flat extract status ok"
if [[ -f "$s/verdicts/divisor-adversary-code.json" ]]; then
	echo "  PASS: flat json written at top level"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no flat json"
	FAIL=$((FAIL + 1))
fi
src=$(mktemp -d)
echo 'x := 1' >"$src/a.go"
result=$(cd "$src" && bash "$VERIFY" "$s")
assert_json_field "$result" "status" "ok" "flat verify status ok"
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: flat finding verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
