#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Write an agent verdict JSON into a session.
agent_json() { # session agent verdict findings_json
	printf '{"agent":"%s","files_read":[],"verdict":"%s","findings":%s}\n' "$2" "$3" "$4" >"$1/verdicts/$2.json"
}

echo "Test 1: missing session"
result=$(bash "$SCRIPT" "/nonexistent" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "nothing_to_do"

echo "Test 2: verified finding + verbatim verdict"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
assert_json_field "$result" "status" "ok" "ok"
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: verified 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
vv=$(jq -r '.verdicts."divisor-adversary-code"' "$s/verdicts/findings.json")
if [[ "$vv" == "REQUEST CHANGES" ]]; then
	echo "  PASS: verdict verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verdict '$vv'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 3: fabricated file stripped"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo "package main" >"$src/real.go"
agent_json "$s" "divisor-testing-code" "REQUEST CHANGES" \
	'[{"severity":"CRITICAL","file":"fake.go","line":10,"evidence":"db.Query(x)","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
sc=$(echo "$result" | jq '.stripped')
if [[ "$sc" -eq 1 ]]; then
	echo "  PASS: stripped 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stripped $sc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 4: dedup same file/evidence"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"HIGH","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" '[{"severity":"MEDIUM","file":"main.go","line":1,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: dedup to 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 5: line outside tolerance -> correctable LINE_MISMATCH"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
printf 'func main() {}\n' >"$src/main.go"
for i in $(seq 2 20); do echo "l$i" >>"$src/main.go"; done
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"HIGH","file":"main.go","line":20,"evidence":"func main() {}","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
cc=$(echo "$result" | jq '.correctable')
if [[ "$cc" -eq 1 ]]; then
	echo "  PASS: correctable 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: correctable $cc"
	FAIL=$((FAIL + 1))
fi
r=$(jq -r '.correctable[0].reason' "$s/verdicts/findings.json")
if [[ "$r" == "LINE_MISMATCH" ]]; then
	echo "  PASS: LINE_MISMATCH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: reason '$r'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 6: tabs in evidence verify against real tabs in source"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
printf '\tif cfg.TLS {\n' >"$src/c.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" '[{"severity":"MEDIUM","file":"c.go","line":1,"evidence":"\tif cfg.TLS {","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: tab evidence verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 7: REVIEW_ROOT prefix, stored path repo-relative"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
root=$(mktemp -d)
mkdir -p "$root/pkg"
echo 'package pkg' >"$root/pkg/x.go"
agent_json "$s" "divisor-guard-code" "APPROVE" '[{"severity":"LOW","file":"pkg/x.go","line":1,"evidence":"package pkg","description":"d","recommendation":"r"}]'
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$s")
stored=$(jq -r '.verified[0].file' "$s/verdicts/findings.json")
if [[ "$stored" == "pkg/x.go" ]]; then
	echo "  PASS: repo-relative path"
	PASS=$((PASS + 1))
else
	echo "  FAIL: '$stored'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$root"

echo "Test 8: mixed null/non-null line, same file+evidence -> must NOT dedup"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"},{"severity":"HIGH","file":"main.go","line":3,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 2 ]]; then
	echo "  PASS: mixed null/non-null line not deduped (2)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 9: two null-line findings, same file+evidence -> DO dedup"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
agent_json "$s" "divisor-adversary-code" "REQUEST CHANGES" \
	'[{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"},{"severity":"HIGH","file":"main.go","line":null,"evidence":"func main() { fmt.Println(\"hi\") }","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: null/null line dedup to 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 10: evidence beginning with '-' verifies (RC-002: grep must not parse it as an option)"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
printf -- '- **Managed** block\n' >"$src/README.md"
agent_json "$s" "divisor-curator-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"README.md","line":1,"evidence":"- **Managed** block","description":"d","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
if [[ "$vc" -eq 1 ]]; then
	echo "  PASS: dash-leading evidence verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified $vc (expected 1)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo "Test 11: dedup keeps MAX severity, HIGH not absorbed into LOW (RC-003)"
s=$(mktemp -d)
mkdir -p "$s/verdicts"
src=$(mktemp -d)
echo 'x := install()' >"$src/a.go"
# One agent, LOW first then HIGH, same file+evidence+line -> deterministic merge order.
agent_json "$s" "divisor-guard-code" "REQUEST CHANGES" \
	'[{"severity":"LOW","file":"a.go","line":1,"evidence":"x := install()","description":"low","recommendation":"r"},{"severity":"HIGH","file":"a.go","line":1,"evidence":"x := install()","description":"high","recommendation":"r"}]'
result=$(cd "$src" && bash "$SCRIPT" "$s")
vc=$(echo "$result" | jq '.verified')
sev=$(jq -r '.verified[0].severity' "$s/verdicts/findings.json")
if [[ "$vc" -eq 1 && "$sev" == "HIGH" ]]; then
	echo "  PASS: merged to 1, severity HIGH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: verified=$vc severity='$sev' (expected 1/HIGH)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$s" "$src"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
