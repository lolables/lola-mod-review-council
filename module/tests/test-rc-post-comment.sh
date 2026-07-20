#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# The router reads Forge from tracking.md and dispatches to
# rc-post-comment-<forge>.sh (passing args through), else runs the renderer
# standalone (render-only fallback). We distinguish the two rendered paths by
# message: the GitHub script's dry-run says "(dry-run)"; the renderer standalone
# says "post it manually".

# Test 1: missing session dir -> skip
echo "Test 1: missing session dir"
result=$(bash "$SCRIPT" /no/such/dir 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"

# Test 2: missing tracking.md -> skip
echo "Test 2: missing tracking.md"
empty=$(mktemp -d)
result=$(bash "$SCRIPT" "$empty" 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip"
rm -rf "$empty"

# Test 3: no PR -> skip (before any dispatch)
echo "Test 3: no PR skips"
sess=$(mktemp -d); make_review_session "$sess" github none
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "skip" "status is skip (no PR)"
rm -rf "$sess"

# Test 4: Forge=github -> dispatches to the GitHub script (dry-run render)
echo "Test 4: dispatch to per-forge script"
sess=$(mktemp -d); make_review_session "$sess" github 42
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered"
echo "$result" | jq -r '.message' | grep -qF "dry-run" && { echo "  PASS: routed to github script"; PASS=$((PASS+1)); } || { echo "  FAIL: not routed to github script"; FAIL=$((FAIL+1)); }
grep -qF "<!-- review-council:marker sha=" "$sess/comment-body.md" && { echo "  PASS: body rendered by github path"; PASS=$((PASS+1)); } || { echo "  FAIL: no body"; FAIL=$((FAIL+1)); }
rm -rf "$sess"

# Test 5: --send is passed through to the per-forge script (auth gate reached)
echo "Test 5: --send passthrough reaches auth gate"
sess=$(mktemp -d); make_review_session "$sess" github 42
ghstub=$(mktemp -d); printf '#!/usr/bin/env bash\nexit 0\n' >"$ghstub/gh"; chmod +x "$ghstub/gh"
result=$(PATH="$ghstub:$PATH" bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "confirm_required" "status is confirm_required (--send reached gate, no ALLOW_POST)"
rm -rf "$sess" "$ghstub"

# Test 6: unsupported forge -> render-only fallback (renderer standalone)
echo "Test 6: unsupported forge render-only fallback"
sess=$(mktemp -d); make_review_session "$sess" gitlab 42
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered (fallback)"
echo "$result" | jq -r '.message' | grep -qF "manually" && { echo "  PASS: render-only fallback message"; PASS=$((PASS+1)); } || { echo "  FAIL: not the fallback path"; FAIL=$((FAIL+1)); }
grep -qF "<!-- review-council:marker sha=" "$sess/comment-body.md" && { echo "  PASS: body rendered by fallback"; PASS=$((PASS+1)); } || { echo "  FAIL: no body"; FAIL=$((FAIL+1)); }
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
