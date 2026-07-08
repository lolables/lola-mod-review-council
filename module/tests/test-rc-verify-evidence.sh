#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-verify-evidence.sh"

# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Test 1: No session directory
echo "Test 1: Missing session directory"
result=$(bash "$SCRIPT" "/nonexistent/path" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"

# Test 2: Empty verdicts directory
echo "Test 2: No verdict files"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
echo "main.go" >"$session/changeset.txt"
result=$(bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"
rm -rf "$session"

# Test 3: Verdict with verifiable evidence
echo "Test 3: Verified finding"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
# Create a source file
src=$(mktemp -d)
echo 'func main() { fmt.Println("hello") }' >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- main.go

### [HIGH] Missing error handling

**File**: `main.go:1`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Error handling required
**Description**: No error handling in main
**Recommendation**: Add error handling
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -gt 0 ]]; then
	echo "  PASS: has verified findings ($verified_count)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no verified findings"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 4: Verdict referencing non-existent file
echo "Test 4: Fabricated file reference"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo "real.go" >"$session/changeset.txt"
echo "package main" >"$src/real.go"
cat >"$session/verdicts/divisor-testing-code.md" <<'VERDICT'
Files read:
- fake.go

### [CRITICAL] SQL injection

**File**: `fake.go:10`
**Evidence**: `db.Query("SELECT * FROM " + input)`
**Constraint**: SQL injection prevention
**Description**: Direct string interpolation in SQL query
**Recommendation**: Use parameterized queries
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
stripped_count=$(echo "$result" | jq '.stripped')
if [[ "$stripped_count" -gt 0 ]]; then
	echo "  PASS: fabricated finding stripped ($stripped_count)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: fabricated finding not stripped"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 5: Deduplication of same-file same-evidence findings
echo "Test 5: Deduplication"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo 'func main() { fmt.Println("hello") }' >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- main.go

### [HIGH] Missing error handling

**File**: `main.go:1`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Error handling required
**Description**: No error handling in main
**Recommendation**: Add error handling
VERDICT
cat >"$session/verdicts/divisor-guard-code.md" <<'VERDICT'
Files read:
- main.go

### [MEDIUM] Missing error handling

**File**: `main.go:1`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Code quality
**Description**: No error handling in main
**Recommendation**: Add error handling
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: duplicate findings consolidated to 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 1 verified finding after dedup, got $verified_count"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 6: Line number mismatch within tolerance
echo "Test 6: Line number tolerance"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
# Create a file where the evidence is on line 3
printf 'line1\nline2\nfunc main() { fmt.Println("hello") }\nline4\n' >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- main.go

### [HIGH] Missing error handling

**File**: `main.go:5`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Error handling required
**Description**: No error handling
**Recommendation**: Add error handling
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: finding within +-5 line tolerance verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: finding within tolerance not verified (got $verified_count)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 7: Line number mismatch outside tolerance
echo "Test 7: Line number outside tolerance"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
# Create a file where the evidence is on line 1, but claim line 20
printf 'func main() { fmt.Println("hello") }\n' >"$src/main.go"
for i in $(seq 2 20); do echo "line$i" >>"$src/main.go"; done
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- main.go

### [HIGH] Missing error handling

**File**: `main.go:20`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Error handling required
**Description**: No error handling
**Recommendation**: Add error handling
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
correctable_count=$(echo "$result" | jq '.correctable')
if [[ "$correctable_count" -eq 1 ]]; then
	echo "  PASS: finding outside tolerance classified as correctable"
	PASS=$((PASS + 1))
else
	echo "  FAIL: finding outside tolerance not correctable (got correctable=$correctable_count)"
	FAIL=$((FAIL + 1))
fi
reason=$(jq -r '.correctable[0].reason' "$session/verdicts/evidence-check.json" 2>/dev/null)
if [[ "$reason" == "LINE_MISMATCH" ]]; then
	echo "  PASS: correctable reason is LINE_MISMATCH"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected LINE_MISMATCH reason, got '$reason'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
