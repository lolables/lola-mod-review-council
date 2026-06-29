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

cat > "$session/tracking.md" <<'TRACKING'
# Review Council Run

## Configuration
- Mode: Code Review
- Branch: feature/auth
- Base: main
- Session: /tmp/test-session

## Phase: Preparation
- Status: complete
- Agents discovered: 6 (divisor-adversary-code, divisor-architect-code, divisor-guard-code, divisor-testing-code, divisor-sre-code, divisor-curator-code)
- Changeset: 5 files
TRACKING

cat > "$session/verdicts/evidence-check.json" <<'EVIDENCE'
{
  "status": "ok",
  "message": "Evidence check complete.",
  "total_findings": 3,
  "verified": [
    {"title": "Missing input validation", "severity": "HIGH", "agent": "divisor-adversary-code", "file": "auth.go:42"}
  ],
  "stripped": [
    {"title": "Fabricated finding", "agent": "divisor-testing-code", "reason": "file does not exist"}
  ],
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
rm -rf "$session"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
