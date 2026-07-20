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

# Test 8: Bare text evidence (no backticks)
echo "Test 8: Bare text evidence"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo 'db.Query("SELECT * FROM users WHERE id=" + userID)' >"$src/handler.go"
echo "handler.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- handler.go

### [CRITICAL] SQL injection via string concatenation

**File**: `handler.go:1`
**Evidence**: db.Query("SELECT * FROM users WHERE id=" + userID)
**Constraint**: SQL injection prevention
**Description**: Direct string concatenation in SQL query
**Recommendation**: Use parameterized queries
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: bare text evidence parsed and verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: bare text evidence not parsed (verified=$verified_count)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 9: Multi-line code block evidence
echo "Test 9: Multi-line code block evidence"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo 'eval(user_input)' >"$src/app.py"
echo "app.py" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- app.py

### [CRITICAL] Code injection via eval

**File**: `app.py:1`
**Evidence**:
```python
eval(user_input)
```
**Constraint**: No eval on untrusted input
**Description**: eval() called with user-controlled data
**Recommendation**: Use ast.literal_eval or a safe parser
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: multi-line code block evidence parsed and verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: multi-line code block evidence not parsed (verified=$verified_count)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 10: File field with line range (path:line-line)
echo "Test 10: File field with line range"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
printf 'line1\nline2\nfunc dangerous() { exec.Command(input) }\nline4\n' >"$src/cmd.go"
echo "cmd.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- cmd.go

### [HIGH] Command injection risk

**File**: `cmd.go:3-4`
**Evidence**: `func dangerous() { exec.Command(input) }`
**Constraint**: Command injection prevention
**Description**: User input passed to exec.Command
**Recommendation**: Validate and sanitize input
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: line range in File field parsed and verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: line range in File field not parsed (verified=$verified_count)"
	FAIL=$((FAIL + 1))
fi
# Verify extracted line number is the start of the range
check_json=$(cat "$session/verdicts/evidence-check.json")
extracted_line=$(echo "$check_json" | jq -r '.verified[0].line')
if [[ "$extracted_line" == "3" ]]; then
	echo "  PASS: extracted start line from range"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected line '3', got '$extracted_line'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 11: File field with bare path (no line number)
echo "Test 11: File field with no line number"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo 'SECRET_KEY = "hardcoded-secret-value"' >"$src/config.py"
echo "config.py" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- config.py

### [CRITICAL] Hardcoded secret

**File**: `config.py`
**Evidence**: `SECRET_KEY = "hardcoded-secret-value"`
**Constraint**: No hardcoded secrets
**Description**: Secret key hardcoded in source
**Recommendation**: Use environment variables
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: bare path (no line number) parsed and verified"
	PASS=$((PASS + 1))
else
	echo "  FAIL: bare path not parsed (verified=$verified_count)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 12: Hard fail — REQUEST CHANGES with no parseable findings
echo "Test 12: Format error on REQUEST CHANGES with no findings"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo "package main" >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
I reviewed the code and found several issues with error handling
and input validation. The code does not properly sanitize user input
which could lead to security vulnerabilities.

Verdict: REQUEST CHANGES
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "format_error" "status is format_error"
error_agent=$(echo "$result" | jq -r '.format_errors[0].agent')
if [[ "$error_agent" == "divisor-adversary-code" ]]; then
	echo "  PASS: format error identifies the agent"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected agent 'divisor-adversary-code', got '$error_agent'"
	FAIL=$((FAIL + 1))
fi
remediation=$(echo "$result" | jq -r '.remediation')
if [[ "$remediation" == *"### [SEVERITY] Title"* ]]; then
	echo "  PASS: remediation includes expected format template"
	PASS=$((PASS + 1))
else
	echo "  FAIL: remediation missing format template"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 13: Soft warning — APPROVE with severity keywords but no structured findings
echo "Test 13: Format warning on APPROVE with severity keywords"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo "package main" >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-guard-code.md" <<'VERDICT'
I reviewed the code thoroughly. There is a MEDIUM risk issue
with the error handling pattern and a LOW priority style concern.
Overall the code is acceptable.

Verdict: APPROVE
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"
warning_count=$(echo "$result" | jq '.format_warnings | length')
if [[ "$warning_count" -eq 1 ]]; then
	echo "  PASS: format warning emitted"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 1 format warning, got $warning_count"
	FAIL=$((FAIL + 1))
fi
warning_agent=$(echo "$result" | jq -r '.format_warnings[0].agent')
if [[ "$warning_agent" == "divisor-guard-code" ]]; then
	echo "  PASS: warning identifies the agent"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected agent 'divisor-guard-code', got '$warning_agent'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 14: Clean APPROVE with no findings and no severity keywords — no warning
echo "Test 14: Clean APPROVE produces no warning"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo "package main" >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-curator-code.md" <<'VERDICT'
I reviewed the documentation and it looks complete and accurate.
No issues found.

Verdict: APPROVE
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "nothing_to_do" "status is nothing_to_do"
has_warnings=$(echo "$result" | jq 'has("format_warnings")')
if [[ "$has_warnings" == "false" ]]; then
	echo "  PASS: no format warnings on clean APPROVE"
	PASS=$((PASS + 1))
else
	echo "  FAIL: unexpected format_warnings on clean APPROVE"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 15: REQUEST CHANGES with proper findings — no error
echo "Test 15: Properly structured REQUEST CHANGES produces no error"
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

Verdict: REQUEST CHANGES
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
has_errors=$(echo "$result" | jq 'has("format_errors")')
if [[ "$has_errors" == "false" ]]; then
	echo "  PASS: no format error on properly structured verdict"
	PASS=$((PASS + 1))
else
	echo "  FAIL: unexpected format_errors on proper verdict"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$src"

# Test 16: REVIEW_ROOT env prefixes finding files (checkout-root case)
echo "Test 16: REVIEW_ROOT prefixing"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
root=$(mktemp -d)
mkdir -p "$root/pkg"
echo 'func main() { fmt.Println("hello") }' >"$root/pkg/main.go"
echo "pkg/main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
Files read:
- pkg/main.go

### [HIGH] Missing error handling

**File**: `pkg/main.go:1`
**Evidence**: `func main() { fmt.Println("hello") }`
**Constraint**: Error handling required
**Description**: No error handling in main
**Recommendation**: Add error handling
VERDICT
# CWD deliberately NOT the checkout root; REVIEW_ROOT points at it.
result=$(REVIEW_ROOT="$root" bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
verified_count=$(echo "$result" | jq '.verified')
if [[ "$verified_count" -eq 1 ]]; then
	echo "  PASS: finding verified via REVIEW_ROOT"
	PASS=$((PASS + 1))
else
	echo "  FAIL: REVIEW_ROOT finding not verified (got $verified_count)"
	FAIL=$((FAIL + 1))
fi
# stored file path stays repo-relative (clean for report/comment)
stored=$(jq -r '.verified[0].file' "$session/verdicts/evidence-check.json")
if [[ "$stored" == "pkg/main.go" ]]; then
	echo "  PASS: stored path is repo-relative"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 'pkg/main.go', got '$stored'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session" "$root"

# Test 17: REVIEW_ROOT unset preserves legacy CWD behavior
echo "Test 17: REVIEW_ROOT unset = legacy behavior"
session=$(mktemp -d)
mkdir -p "$session/verdicts"
src=$(mktemp -d)
echo 'package main' >"$src/real.go"
echo "real.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-testing-code.md" <<'VERDICT'
Files read:
- real.go

### [LOW] Package comment missing

**File**: `real.go:1`
**Evidence**: `package main`
**Constraint**: Doc comment
**Description**: No package doc
**Recommendation**: Add one
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok (legacy path)"
rm -rf "$session" "$src"

# Test 18: full finding body captured verbatim into `detail`
echo "Test 18: detail captures full reviewer body verbatim"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
echo 'if IsPuppetOID(ext.Id) {' >"$src/signing.go"
echo "signing.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-testing-code.md" <<'VERDICT'
Files read:
- signing.go

### [HIGH] Carry-forward untested

**File**: `signing.go:1`
**Evidence**: `if IsPuppetOID(ext.Id) {`

Context in AutoRenew:
```go
for _, ext := range presentedCert.Extensions {
    if IsPuppetOID(ext.Id) {
```
**Search proving absence**: `grep IsAuthOID renew_test.go` returned nothing.
**Description**: The loop is a deliberate security divergence.
**Recommendation**: Add an `It` that seeds a presentedCert and asserts extensions.

Verdict: REQUEST CHANGES
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "ok" "status is ok"
detail=$(jq -r '.verified[0].detail' "$session/verdicts/evidence-check.json")
for needle in "Context in AutoRenew" "Search proving absence" "for _, ext := range" "**Recommendation**: Add an" "deliberate security divergence"; do
	if grep -qF "$needle" <<<"$detail"; then echo "  PASS: detail has '$needle'"; PASS=$((PASS+1)); else echo "  FAIL: detail missing '$needle'"; FAIL=$((FAIL+1)); fi
done
# boundary: the trailing verdict declaration must NOT bleed into detail
if grep -qF "REQUEST CHANGES" <<<"$detail"; then echo "  FAIL: detail absorbed the verdict line"; FAIL=$((FAIL+1)); else echo "  PASS: detail stops before verdict line"; PASS=$((PASS+1)); fi
rm -rf "$session" "$src"

# Test 19: last finding does not absorb a `## Verdict` / notes section
echo "Test 19: detail stops at a section boundary"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
echo 'package main' >"$src/a.go"
echo "a.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-guard-code.md" <<'VERDICT'
### [LOW] Doc missing

**File**: `a.go:1`
**Evidence**: `package main`
**Recommendation**: Add a package comment.

---

## Verdict

**Verdict**: REQUEST CHANGES
This section must never appear inside detail.
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
detail=$(jq -r '.verified[0].detail' "$session/verdicts/evidence-check.json")
if grep -qF "Add a package comment" <<<"$detail" && ! grep -qF "must never appear" <<<"$detail" && ! grep -qF "## Verdict" <<<"$detail"; then
	echo "  PASS: detail contains the finding body but not the trailing section"; PASS=$((PASS+1))
else
	echo "  FAIL: boundary wrong (detail='$detail')"; FAIL=$((FAIL+1))
fi
rm -rf "$session" "$src"

# Test 20: existing finding fields are unchanged by detail capture (regression)
echo "Test 20: core fields intact alongside detail"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
echo 'func main() { fmt.Println("hi") }' >"$src/main.go"
echo "main.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-adversary-code.md" <<'VERDICT'
### [HIGH] X

**File**: `main.go:1`
**Evidence**: `func main() { fmt.Println("hi") }`
**Recommendation**: Do the thing.
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
title=$(jq -r '.verified[0].title' "$session/verdicts/evidence-check.json")
ev=$(jq -r '.verified[0].evidence' "$session/verdicts/evidence-check.json")
if [[ "$title" == "X" && "$ev" == 'func main() { fmt.Println("hi") }' ]]; then
	echo "  PASS: title/evidence still parsed correctly"; PASS=$((PASS+1))
else
	echo "  FAIL: core fields wrong (title='$title' ev='$ev')"; FAIL=$((FAIL+1))
fi
rm -rf "$session" "$src"

# Test 21: File with a bare path + trailing prose (no backticks) parses to the path
echo "Test 21: bare path with prose in File"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
mkdir -p "$src/internal/api"
echo 'http.Error(w, "x", http.StatusUnprocessableEntity)' >"$src/internal/api/handlers.go"
echo "internal/api/handlers.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-testing-code.md" <<'VERDICT'
### [MEDIUM] 422 mapping untested

**File**: internal/api/handlers.go (lines 869-872 and 899-902); gap confirmed against internal/api/api_test.go
**Evidence**: `http.Error(w, "x", http.StatusUnprocessableEntity)`
**Recommendation**: Add a handler test.
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
f=$(jq -r '.verified[0].file' "$session/verdicts/evidence-check.json" 2>/dev/null)
if [[ "$f" == "internal/api/handlers.go" ]]; then echo "  PASS: extracted bare path from prose"; PASS=$((PASS+1)); else echo "  FAIL: got file '$f'"; FAIL=$((FAIL+1)); fi
rm -rf "$session" "$src"

# Test 22: File with bare path:line then backticked function names picks the PATH
echo "Test 22: path:line not confused by backticked function names"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
mkdir -p "$src/internal/ca"
printf 'line1\nline2\nfunc issueLeafLocked() {}\n' >"$src/internal/ca/signing.go"
echo "internal/ca/signing.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-sre-code.md" <<'VERDICT'
### [LOW] inventory growth

**File**: internal/ca/signing.go:3, 428 (via `issueLeafLocked`), driven by `AutoRenew`
**Evidence**: `func issueLeafLocked() {}`
**Recommendation**: Add compaction.
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
f=$(jq -r '.verified[0].file' "$session/verdicts/evidence-check.json" 2>/dev/null)
ln=$(jq -r '.verified[0].line' "$session/verdicts/evidence-check.json" 2>/dev/null)
if [[ "$f" == "internal/ca/signing.go" && "$ln" == "3" ]]; then echo "  PASS: picked path:line, not function name"; PASS=$((PASS+1)); else echo "  FAIL: got file='$f' line='$ln'"; FAIL=$((FAIL+1)); fi
rm -rf "$session" "$src"

# Test 23: a finding header that fails to parse triggers format_error even on APPROVE
echo "Test 23: unparseable finding block flagged (silent-drop guard)"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
echo 'package main' >"$src/x.go"
echo "x.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-testing-code.md" <<'VERDICT'
### [MEDIUM] Something is missing

**Evidence**: `package main`
**Recommendation**: Add a test.

Verdict: APPROVE
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "format_error" "unparseable finding -> format_error"
agent=$(echo "$result" | jq -r '.format_errors[0].agent')
[[ "$agent" == "divisor-testing-code" ]] && { echo "  PASS: names the agent"; PASS=$((PASS+1)); } || { echo "  FAIL: agent '$agent'"; FAIL=$((FAIL+1)); }
rm -rf "$session" "$src"

# Test 24: partial parse failure (one of two findings unparseable) -> format_error
echo "Test 24: partial parse failure flagged"
session=$(mktemp -d); mkdir -p "$session/verdicts"; src=$(mktemp -d)
printf 'package main\nfunc F() {}\n' >"$src/y.go"
echo "y.go" >"$session/changeset.txt"
cat >"$session/verdicts/divisor-guard-code.md" <<'VERDICT'
### [LOW] Good finding

**File**: `y.go:1`
**Evidence**: `package main`
**Recommendation**: none

### [MEDIUM] Broken finding (no File)

**Evidence**: `func F() {}`
**Recommendation**: fix

Verdict: REQUEST CHANGES
VERDICT
result=$(cd "$src" && bash "$SCRIPT" "$session" 2>/dev/null)
assert_json_field "$result" "status" "format_error" "partial parse failure -> format_error"
rm -rf "$session" "$src"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
