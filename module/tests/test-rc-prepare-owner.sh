#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

echo "Test 1: session.txt records owner/repo from origin"
work=$(mktemp -d)
setup_repo "$work" feature
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code 2>/dev/null)
sess=$(echo "$result" | jq -r '.session_dir')
if grep -q "^Owner:.*acme" "$sess/session.txt" && grep -q "^Repo:.*widgets" "$sess/session.txt"; then
	echo "  PASS: owner/repo recorded"
	PASS=$((PASS + 1))
else
	echo "  FAIL: owner/repo missing from session.txt"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
