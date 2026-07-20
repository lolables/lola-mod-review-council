#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

echo "Test 1: prepare emits review_root=. for local non-PR review"
work=$(mktemp -d)
(
	cd "$work"
	git init -q; git config user.email t@t.local; git config user.name t
	git checkout -q -b main
	echo "package main" >a.go; git add a.go; git commit -qm init
	git checkout -q -b feature
	echo "// change" >>a.go; git commit -qam change
)
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code 2>/dev/null)
assert_json_field "$result" "review_root" "." "review_root defaults to ."
rm -rf "$work"

echo "Test 2: prepare records post-comment intent flags"
work=$(mktemp -d)
(
	cd "$work"
	git init -q; git config user.email t@t.local; git config user.name t
	git checkout -q -b main
	echo "package main" >a.go; git add a.go; git commit -qm init
	git checkout -q -b feature
	echo "// change" >>a.go; git commit -qam change
)
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code --post-comment 2>/dev/null)
sess=$(echo "$result" | jq -r '.session_dir')
if grep -q "Post intent: yes" "$sess/tracking.md"; then
	echo "  PASS: post intent recorded in tracking"; PASS=$((PASS+1))
else
	echo "  FAIL: post intent not in tracking"; FAIL=$((FAIL+1))
fi
rm -rf "$work"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
