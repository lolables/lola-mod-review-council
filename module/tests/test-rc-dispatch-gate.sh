#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
SKILL_MD="$SCRIPT_DIR/../skills/review-council/SKILL.md"
DELEGATE_MD="$SCRIPT_DIR/../skills/review-council/phases/delegate.md"

# Fail-closed dispatch gate (ISSUE.md): the orchestrator must dispatch ONLY the
# reviewer identifiers returned in rc-prepare.sh's `agents` array. Un-suffixed
# legacy divisor-* files left by an older install may still be registered as
# dispatchable in the host; the skill must forbid using them.

echo "Test: SKILL.md restricts dispatch to the discovered agents array"
if grep -qiE 'dispatch only .*(agents|identifiers)|only .*identifiers .*agents.? array' "$SKILL_MD"; then
	echo "  PASS: dispatch restricted to discovered array"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no restriction of dispatch to the discovered array"
	FAIL=$((FAIL + 1))
fi

echo "Test: SKILL.md warns against un-suffixed legacy host agents"
if grep -qiE 'un-suffixed|legacy .*divisor' "$SKILL_MD"; then
	echo "  PASS: SKILL.md warns about legacy/un-suffixed agents"
	PASS=$((PASS + 1))
else
	echo "  FAIL: SKILL.md does not warn about legacy/un-suffixed agents"
	FAIL=$((FAIL + 1))
fi

echo "Test: delegate.md warns against dispatching agents outside the discovered array"
if grep -qiE 'un-suffixed|legacy .*divisor|absent from that array|not in .*discovered' "$DELEGATE_MD"; then
	echo "  PASS: delegate.md forbids out-of-array dispatch"
	PASS=$((PASS + 1))
else
	echo "  FAIL: delegate.md does not forbid out-of-array dispatch"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
