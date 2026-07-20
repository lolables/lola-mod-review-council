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

# Test 3: nested analysis <details> rendered when detail present
echo "Test 3: nested reviewer-analysis details"
sess=$(mktemp -d); make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body=$(cat "$sess/comment-body.md")
if grep -qF "<details><summary>💬 Full reviewer analysis</summary>" <<<"$body"; then
	echo "  PASS: nested 💬 summary present"; PASS=$((PASS+1))
else
	echo "  FAIL: nested summary missing"; FAIL=$((FAIL+1))
fi
# Recommendation is hoisted OUT of the analysis, always visible, lightbulb-tagged,
# with the body on a bullet below the label.
if grep -Pzoq '  💡 \*\*Recommendation:\*\*\n  - Use `<=`' "$sess/comment-body.md"; then
	echo "  PASS: recommendation label + bulleted body"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not label+bullet"; FAIL=$((FAIL+1))
fi
# the recommendation's trailing code snippet nests inside the bullet (4-space indent)
if grep -qE '^    ```go' "$sess/comment-body.md" && grep -qE '^    if exp <= now \{' "$sess/comment-body.md"; then
	echo "  PASS: recommendation code snippet nested in bullet"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation snippet not nested"; FAIL=$((FAIL+1))
fi
# the raw reviewer label is gone (hoisted + relabeled, never duplicated)
if ! grep -qF "**Recommendation**:" <<<"$body"; then
	echo "  PASS: raw **Recommendation**: label removed"; PASS=$((PASS+1))
else
	echo "  FAIL: raw **Recommendation**: label still present"; FAIL=$((FAIL+1))
fi
# Recommendation renders ABOVE its Full reviewer analysis block.
rec_ln=$(grep -n '💡 \*\*Recommendation:\*\*' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
ana_ln=$(grep -n '💬 Full reviewer analysis' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
if [[ -n "$rec_ln" && -n "$ana_ln" && "$rec_ln" -lt "$ana_ln" ]]; then
	echo "  PASS: recommendation above full analysis ($rec_ln < $ana_ln)"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not above analysis (rec=$rec_ln ana=$ana_ln)"; FAIL=$((FAIL+1))
fi
# redundant **File**: preamble is stripped (it is already the finding's link)
if ! grep -qF "**File**:" <<<"$body"; then
	echo "  PASS: redundant File preamble stripped"; PASS=$((PASS+1))
else
	echo "  FAIL: File preamble not stripped"; FAIL=$((FAIL+1))
fi
# FENCED evidence is kept (a multi-line block carries more than the teaser)
if grep -qF "**Evidence**:" <<<"$body" && grep -qzF $'  \`\`\`go\n  if exp < now\n  \`\`\`' "$sess/comment-body.md"; then
	echo "  PASS: fenced evidence retained in analysis"; PASS=$((PASS+1))
else
	echo "  FAIL: fenced evidence wrongly dropped"; FAIL=$((FAIL+1))
fi
# no stray leading blank line right after the analysis summary
if grep -Pzoq '💬 Full reviewer analysis</summary>\n\n  \*\*Evidence\*\*:' "$sess/comment-body.md"; then
	echo "  PASS: analysis starts cleanly (no stray blank)"; PASS=$((PASS+1))
else
	echo "  FAIL: stray blank line after summary"; FAIL=$((FAIL+1))
fi
# INLINE evidence (fully shown in the teaser) IS stripped as redundant
sess2=$(mktemp -d); make_review_session "$sess2"
jq '.verified[0].detail = "**Evidence**: `if exp < now`\n\n**Recommendation**: Use <=."' "$sess2/verdicts/evidence-check.json" >"$sess2/verdicts/ec.tmp" && mv "$sess2/verdicts/ec.tmp" "$sess2/verdicts/evidence-check.json"
bash "$SCRIPT" "$sess2" >/dev/null 2>&1
# inline evidence stripped; recommendation still surfaces (hoisted, label+bullet)
if ! grep -qF "**Evidence**: \`if exp < now\`" "$sess2/comment-body.md" && grep -Pzoq '💡 \*\*Recommendation:\*\*\n  - Use <=\.' "$sess2/comment-body.md"; then
	echo "  PASS: inline evidence stripped, recommendation kept"; PASS=$((PASS+1))
else
	echo "  FAIL: inline evidence not stripped or recommendation dropped"; FAIL=$((FAIL+1))
fi
rm -rf "$sess2"
# recommendation label is indented two spaces to stay inside the list item
if grep -qE '^  💡 \*\*Recommendation:\*\*$' "$sess/comment-body.md"; then
	echo "  PASS: recommendation indented into list item"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not indented"; FAIL=$((FAIL+1))
fi
# Description body is moved onto a bullet below its label
if grep -Pzoq '  \*\*Description:\*\*\n  - The expiry check' "$sess/comment-body.md"; then
	echo "  PASS: description label + bulleted body"; PASS=$((PASS+1))
else
	echo "  FAIL: description not label+bullet"; FAIL=$((FAIL+1))
fi
# a <br> spacer renders one blank line of whitespace before the analysis block
if grep -Pzoq '  <br>\n\n  <details><summary>💬 Full reviewer analysis' "$sess/comment-body.md"; then
	echo "  PASS: <br> spacer before full analysis"; PASS=$((PASS+1))
else
	echo "  FAIL: no <br> spacer before full analysis"; FAIL=$((FAIL+1))
fi
# both details tags balance (2 open: severity + analysis; 2 close)
opens=$(grep -cF "<details>" "$sess/comment-body.md"); closes=$(grep -cF "</details>" "$sess/comment-body.md")
if [[ "$opens" -eq "$closes" && "$opens" -ge 2 ]]; then
	echo "  PASS: details tags balanced ($opens/$closes)"; PASS=$((PASS+1))
else
	echo "  FAIL: details tags unbalanced ($opens/$closes)"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 4: no nested block when detail is empty (graceful fallback)
echo "Test 4: no nested block when detail empty"
sess=$(mktemp -d); make_review_session "$sess"
jq '.verified[0].detail = ""' "$sess/verdicts/evidence-check.json" >"$sess/verdicts/ec.tmp" && mv "$sess/verdicts/ec.tmp" "$sess/verdicts/evidence-check.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qF "💬 Full reviewer analysis" "$sess/comment-body.md"; then
	echo "  PASS: no nested block for empty detail"; PASS=$((PASS+1))
else
	echo "  FAIL: nested block emitted for empty detail"; FAIL=$((FAIL+1))
fi
grep -qF "auth/token.go:1" "$sess/comment-body.md" && { echo "  PASS: finding still present"; PASS=$((PASS+1)); } || { echo "  FAIL: finding dropped"; FAIL=$((FAIL+1)); }
rm -rf "$sess"

# Test 5: dense reviewer body gets blank-line separation between fields
echo "Test 5: dense analysis fields separated for readability"
sess=$(mktemp -d); make_review_session "$sess"
# jam Constraint/Description onto adjacent lines (the real-world "wall of text");
# Recommendation is hoisted, so the analysis holds Constraint + Description only.
jq '.verified[0].detail = "**Constraint**: convention X\n**Description**: long explanation here\n**Recommendation**: do the fix"' \
	"$sess/verdicts/evidence-check.json" >"$sess/verdicts/ec.tmp" && mv "$sess/verdicts/ec.tmp" "$sess/verdicts/evidence-check.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
# jammed Constraint/Description each become a label heading + bulleted body,
# separated by a blank line (distinct paragraphs, not one <br>-joined wall)
if grep -Pzoq '  \*\*Constraint:\*\*\n  - convention X\n\n  \*\*Description:\*\*\n  - long explanation here' "$sess/comment-body.md"; then
	echo "  PASS: jammed fields split into label + bullet"; PASS=$((PASS+1))
else
	echo "  FAIL: jammed fields not split into label + bullet"; FAIL=$((FAIL+1))
fi
# recommendation still hoisted out (label + bullet), and not left in the body
if grep -Pzoq '💡 \*\*Recommendation:\*\*\n  - do the fix' "$sess/comment-body.md" && ! grep -qF "**Recommendation**: do the fix" "$sess/comment-body.md"; then
	echo "  PASS: recommendation hoisted from dense body"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not hoisted from dense body"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
