#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-render-report.sh"
PASS=0
FAIL=0

# Test 1: Missing session directory
echo "Test 1: Missing session directory"
result=$(bash "$SCRIPT" "/nonexistent/path" 2>/dev/null)
if echo "$result" | grep -qi "not available\|not found\|no session"; then
	echo "  PASS: graceful message for missing session"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no graceful message"
	FAIL=$((FAIL + 1))
fi

# Test 2: Valid session with tracking and evidence data
echo "Test 2: Valid session"
session=$(mktemp -d)
mkdir -p "$session/verdicts"

cat >"$session/tracking.md" <<'TRACKING'
# Review Council Session Tracking

## Phase: Preparation

- Input type: auto
- Forge: local
- Tooling: none
- PR: none
- Linked issues: 0
- Prior reviews: 0
- Constitution: none
- Mode: code (code files changed)
- Branch: feature/auth
- Base: main
- Language: go
- Framework: none
- Agents discovered: 6
- Agents absent: none
- Changeset size: 5 files
TRACKING

cat >"$session/verdicts/evidence-check.json" <<'EVIDENCE'
{
  "verified": [
    {"agent": "divisor-adversary-code", "severity": "HIGH", "title": "Missing input validation", "file": "auth.go", "line": "42", "evidence": "user_input := r.URL.Query()"}
  ],
  "correctable": [],
  "stripped": [
    {"agent": "divisor-testing-code", "severity": "CRITICAL", "title": "Fabricated finding", "file": "fake.go", "line": "", "evidence": "nonexistent", "reason": "FILE_NOT_FOUND"}
  ],
  "total_findings": 3,
  "duplicates_consolidated": 1
}
EVIDENCE

result=$(bash "$SCRIPT" "$session" 2>/dev/null)
if echo "$result" | grep -q "Review Council"; then
	echo "  PASS: report contains header"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing header"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "feature/auth"; then
	echo "  PASS: report contains branch name"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing branch name"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "Missing input validation"; then
	echo "  PASS: report contains verified finding title"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing verified finding title"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "divisor-adversary-code"; then
	echo "  PASS: report contains agent name"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing agent name"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "HIGH"; then
	echo "  PASS: report contains severity level"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing severity level"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "Correctable"; then
	echo "  PASS: report contains correctable count"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing correctable count"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | grep -q "Changeset"; then
	echo "  PASS: report contains changeset size"
	PASS=$((PASS + 1))
else
	echo "  FAIL: report missing changeset size"
	FAIL=$((FAIL + 1))
fi
rm -rf "$session"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
