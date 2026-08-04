#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
SKILL_MD="$SCRIPT_DIR/../skills/review-council/SKILL.md"

echo "Test: SKILL.md derives REFERENCES_DIR from SKILL_DIR"
if grep -qE 'REFERENCES_DIR=.*SKILL_DIR/references|references relative to .*SKILL_DIR|\$\{SKILL_DIR\}/references' "$SKILL_MD"; then
	echo "  PASS: references anchored on SKILL_DIR"
	PASS=$((PASS + 1))
else
	echo "  FAIL: references not anchored on SKILL_DIR"
	FAIL=$((FAIL + 1))
fi

echo "Test: MODULE_DIR-derived references path removed"
if grep -qE 'REFERENCES_DIR=.*MODULE_DIR/references' "$SKILL_MD"; then
	echo "  FAIL: MODULE_DIR-derived references path remains"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no MODULE_DIR references path"
	PASS=$((PASS + 1))
fi

echo "Test: SKILL.md derives AGENTS_DIR from MODULE_DIR (concrete, resolvable)"
if grep -qE 'AGENTS_DIR="\$\{MODULE_DIR\}/agents"' "$SKILL_MD"; then
	echo "  PASS: AGENTS_DIR derivation is concrete"
	PASS=$((PASS + 1))
else
	echo "  FAIL: AGENTS_DIR derivation missing or not concrete"
	FAIL=$((FAIL + 1))
fi

echo "Test: AGENTS_DIR is not a placeholder"
if grep -q 'AGENTS_DIR="<' "$SKILL_MD"; then
	echo "  FAIL: AGENTS_DIR placeholder found"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no AGENTS_DIR placeholder"
	PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
