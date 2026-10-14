#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

echo "Test 1: prepare emits review_root=. for local non-PR review"
work=$(mktemp -d)
setup_repo "$work" feature ""
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code 2>/dev/null)
assert_json_field "$result" "review_root" "." "review_root defaults to ."
rm -rf "$work"

echo "Test 2: prepare records post-comment intent flags"
work=$(mktemp -d)
setup_repo "$work" feature ""
result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code --post-comment 2>/dev/null)
sess=$(echo "$result" | jq -r '.session_dir')
if grep -q "Post intent: yes" "$sess/tracking.md"; then
	echo "  PASS: post intent recorded in tracking"
	PASS=$((PASS + 1))
else
	echo "  FAIL: post intent not in tracking"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work"

# The posters' intent gate (rc_post_intent_refusal) reads session.txt, never
# tracking.md, and opens only when the value's first token is exactly `yes`.
# The poster suites build session.txt by hand, so only this pins the producer.
for case in "--post-comment:yes" "--post-auto-send:yes" ":no"; do
	flag="${case%%:*}" want="${case##*:}"
	echo "Test 3: session.txt records Post intent '${want}' for '${flag:-no post flag}'"
	work=$(mktemp -d)
	setup_repo "$work" feature ""
	result=$(cd "$work" && AGENTS_DIR="$SCRIPT_DIR/../agents" bash "$SCRIPT" --mode code ${flag:+"$flag"} 2>/dev/null)
	sess=$(echo "$result" | jq -r '.session_dir')
	if grep -qE "^Post intent:[[:space:]]+${want}([[:space:]]|$)" "$sess/session.txt"; then
		echo "  PASS: session.txt Post intent starts with '${want}'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: session.txt Post intent does not start with '${want}'"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$work"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
