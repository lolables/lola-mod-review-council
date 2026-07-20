#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$SCRIPT_DIR/../skills/review-council/scripts/rc-lib.sh"

echo "Test 1: rc_parse_kv reads a trimmed value"
f=$(mktemp)
printf -- '- Forge: github\n- PR: 42\n- Mode: code (default)\n' >"$f"
val=$(rc_parse_kv "$f" "Forge")
[[ "$val" == "github" ]] && { echo "  PASS: Forge=github"; PASS=$((PASS+1)); } \
	|| { echo "  FAIL: got '$val'"; FAIL=$((FAIL+1)); }

echo "Test 2: rc_parse_kv returns empty for a missing key"
val=$(rc_parse_kv "$f" "Nope")
[[ -z "$val" ]] && { echo "  PASS: missing key empty"; PASS=$((PASS+1)); } \
	|| { echo "  FAIL: got '$val'"; FAIL=$((FAIL+1)); }

echo "Test 3: rc_parse_kv keeps only the first line's value"
val=$(rc_parse_kv "$f" "Mode")
[[ "$val" == "code (default)" ]] && { echo "  PASS: Mode value intact"; PASS=$((PASS+1)); } \
	|| { echo "  FAIL: got '$val'"; FAIL=$((FAIL+1)); }
rm -f "$f"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
