#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-render-comment.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Test 1: standalone render -> plain code spans (no hooks defined), full body
echo "Test 1: standalone render (plain spans)"
sess=$(mktemp -d); make_review_session "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered"
body=$(cat "$sess/comment-body.md")
for needle in "Review Council: REQUEST CHANGES" "TL;DR" "Reviewed at commit" "(high effort)" "auth/token.go:1" "🛡️" "<!-- review-council:marker sha=" "Produced by [Review Council]"; do
	if grep -qF "$needle" <<<"$body"; then echo "  PASS: contains '$needle'"; PASS=$((PASS+1)); else echo "  FAIL: missing '$needle'"; FAIL=$((FAIL+1)); fi
done
# plain mode: no forge deep-links
if ! grep -qF "/blob/" <<<"$body" && ! grep -qF "/commit/" <<<"$body"; then
	echo "  PASS: no deep-links in plain mode"; PASS=$((PASS+1))
else
	echo "  FAIL: deep-links leaked into plain mode"; FAIL=$((FAIL+1))
fi
# no em/en dashes
if ! grep -qP '[\x{2014}\x{2013}]' "$sess/comment-body.md"; then
	echo "  PASS: no em/en dashes"; PASS=$((PASS+1))
else
	echo "  FAIL: em/en dash present"; FAIL=$((FAIL+1))
fi
# blank line between finding title and its quote
if grep -Pzoq '\*\*expiry uses < not <=\*\*[^\n]*\n\n  > ' "$sess/comment-body.md"; then
	echo "  PASS: blank line before quote"; PASS=$((PASS+1))
else
	echo "  FAIL: no blank line before quote"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 2: sourced render with stub hooks -> markdown deep-links + exports set
echo "Test 2: sourced render with hooks (deep-links + exports)"
sess=$(mktemp -d); make_review_session "$sess"
printf 'divisor-adversary-code: claude-opus-4-8\ndivisor-guard-code: claude-opus-4-8\n' >"$sess/models.txt"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_url_file()   { printf '%s/blob/%s/%s#L%s' "$1" "$2" "$3" "$4"; }
	rc_url_commit() { printf '%s/commit/%s' "$1" "$2"; }
	rc_render_comment_body "$sess" "$sess/body.md"
	{ echo "$RC_FORGE_WEB"; echo "$RC_SHORT_SHA"; echo "$RC_HEAD_SHA"; } >"$sess/exports"
)
b2=$(cat "$sess/body.md")
if grep -qF "https://github.example.com/acme/widgets/blob/" <<<"$b2" && grep -qF "#L1" <<<"$b2"; then
	echo "  PASS: finding deep-link built via rc_url_file"; PASS=$((PASS+1))
else
	echo "  FAIL: finding deep-link missing"; FAIL=$((FAIL+1))
fi
if grep -qF "https://github.example.com/acme/widgets/commit/" <<<"$b2"; then
	echo "  PASS: commit stamp link built via rc_url_commit"; PASS=$((PASS+1))
else
	echo "  FAIL: commit stamp link missing"; FAIL=$((FAIL+1))
fi
if grep -qF "> - claude-opus-4-8" <<<"$b2" && [[ "$(grep -c 'claude-opus-4-8' <<<"$b2")" -eq 1 ]]; then
	echo "  PASS: provenance bullet deduped"; PASS=$((PASS+1))
else
	echo "  FAIL: provenance bullets wrong"; FAIL=$((FAIL+1))
fi
web=$(sed -n 1p "$sess/exports"); short=$(sed -n 2p "$sess/exports"); full=$(sed -n 3p "$sess/exports")
if [[ "$web" == "https://github.example.com/acme/widgets" && -n "$short" && "${full:0:7}" == "$short" ]]; then
	echo "  PASS: exports RC_FORGE_WEB/RC_SHORT_SHA/RC_HEAD_SHA set"; PASS=$((PASS+1))
else
	echo "  FAIL: exports wrong (web='$web' short='$short' full='$full')"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
