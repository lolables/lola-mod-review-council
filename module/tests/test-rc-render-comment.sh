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
for needle in "Review Council: REQUEST CHANGES" "TL;DR" "Reviewed at commit" "(high effort)" "auth/token.go:1" "🛡️" "<!-- review-council:marker sha=" "Produced by [Review Council]" "💡 **Recommendation:**" "💬 Full reviewer analysis"; do
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
if grep -Pzoq '\*\*The expiry check rejects tokens at the exact boundary\.\*\*[^\n]*\n\n  > ' "$sess/comment-body.md"; then
	echo "  PASS: blank line before quote"; PASS=$((PASS+1))
else
	echo "  FAIL: no blank line before quote"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 2: sourced render with stub hooks -> markdown deep-links + exports set
echo "Test 2: sourced render with hooks (deep-links + exports)"
sess=$(mktemp -d); make_review_session "$sess"
cat >"$sess/models.json" <<'MJ'
[{"role":"divisor-adversary-code","id":"claude-opus-4-8"},{"role":"divisor-guard-code","id":"claude-opus-4-8"}]
MJ
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
# two models.json entries share the same id -> deduped to a single bullet
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

# Test 3: findings render deterministically from findings.json fields (no
# base64 detail blob, no awk re-segmentation) - recommendation and
# description are separate fields, rendered as-is.
echo "Test 3: deterministic field rendering (recommendation + analysis)"
sess=$(mktemp -d); make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body=$(cat "$sess/comment-body.md")
if grep -qF "<details><summary>💬 Full reviewer analysis</summary>" <<<"$body"; then
	echo "  PASS: nested 💬 summary present"; PASS=$((PASS+1))
else
	echo "  FAIL: nested summary missing"; FAIL=$((FAIL+1))
fi
# Recommendation field renders verbatim, lightbulb-tagged, inline (single line).
if grep -qF '  💡 **Recommendation:** Use `<=` so a token expiring exactly now is still valid.' "$sess/comment-body.md"; then
	echo "  PASS: recommendation field rendered verbatim"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not rendered verbatim"; FAIL=$((FAIL+1))
fi
# Description field renders verbatim inside the collapsed analysis.
if grep -qF '  The expiry check rejects tokens at the exact boundary.' "$sess/comment-body.md"; then
	echo "  PASS: description rendered inside analysis"; PASS=$((PASS+1))
else
	echo "  FAIL: description missing from analysis"; FAIL=$((FAIL+1))
fi
# Recommendation renders ABOVE its Full reviewer analysis block.
rec_ln=$(grep -n '💡 \*\*Recommendation:\*\*' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
ana_ln=$(grep -n '💬 Full reviewer analysis' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
if [[ -n "$rec_ln" && -n "$ana_ln" && "$rec_ln" -lt "$ana_ln" ]]; then
	echo "  PASS: recommendation above full analysis ($rec_ln < $ana_ln)"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation not above analysis (rec=$rec_ln ana=$ana_ln)"; FAIL=$((FAIL+1))
fi
# both details tags balance (2 open: severity + analysis; 2 close)
opens=$(grep -cF "<details>" "$sess/comment-body.md"); closes=$(grep -cF "</details>" "$sess/comment-body.md")
if [[ "$opens" -eq "$closes" && "$opens" -ge 2 ]]; then
	echo "  PASS: details tags balanced ($opens/$closes)"; PASS=$((PASS+1))
else
	echo "  FAIL: details tags unbalanced ($opens/$closes)"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 4: no title field -> falls back to first ~60 chars of description
echo "Test 4: title falls back to description prefix"
sess=$(mktemp -d); make_review_session "$sess"
jq '.verified[0].title = null' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "**The expiry check rejects tokens at the exact boundary.**" "$sess/comment-body.md"; then
	echo "  PASS: title falls back to description prefix"; PASS=$((PASS+1))
else
	echo "  FAIL: title fallback not rendered"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 5: RC_BUGS #1/#2 guard - real-tab evidence and provenance.calibrated_from
# must never leak raw JSON-escape sequences or a calibration HTML comment into
# the posted body. Direct guard against the PR-114/115 @tsv + detail bleed:
# jq -r field access (never @tsv) means an embedded tab travels through as a
# real tab byte, not the two-character "\t" escape sequence, and provenance is
# never touched by the renderer at all.
echo "Test 5: tab evidence + calibration provenance does not bleed into body"
sess=$(mktemp -d); make_review_session "$sess"
mkdir -p "$sess/checkout/net"
printf '\tif cfg.TLS {\n' >"$sess/checkout/net/tls.go"
jq '.verified[0] = {
	"agent":"divisor-adversary-code","severity":"CRITICAL","file":"net/tls.go","line":1,
	"evidence":"\tif cfg.TLS {",
	"description":"TLS config is dereferenced without a nil check.",
	"recommendation":"Guard cfg.TLS before dereferencing it.",
	"status":"verified","verdict":"REQUEST CHANGES",
	"provenance":{"calibrated_from":"divisor-adversary-code prior run"}
}' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qF '\t' "$sess/comment-body.md"; then
	echo "  PASS: no literal backslash-t escape sequence in body"; PASS=$((PASS+1))
else
	echo "  FAIL: literal backslash-t escape leaked into body"; FAIL=$((FAIL+1))
fi
if ! grep -qF '\' "$sess/comment-body.md"; then
	echo "  PASS: no stray backslash literal in body"; PASS=$((PASS+1))
else
	echo "  FAIL: stray backslash literal leaked into body"; FAIL=$((FAIL+1))
fi
if grep -qP '\tif cfg\.TLS \{' "$sess/comment-body.md"; then
	echo "  PASS: real tab byte from evidence preserved"; PASS=$((PASS+1))
else
	echo "  FAIL: real tab byte from evidence missing"; FAIL=$((FAIL+1))
fi
if ! grep -qi "calibrat" "$sess/comment-body.md"; then
	echo "  PASS: no calibration HTML comment leaked"; PASS=$((PASS+1))
else
	echo "  FAIL: calibration provenance leaked into body"; FAIL=$((FAIL+1))
fi
if grep -qF "Guard cfg.TLS before dereferencing it." "$sess/comment-body.md"; then
	echo "  PASS: recommendation text present"; PASS=$((PASS+1))
else
	echo "  FAIL: recommendation text missing"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 6: multi-line evidence must not bleed into the surrounding markdown
# structure. evidence is schema-permitted to be multi-line; jq -r turns its
# JSON \n into real newlines, so a naive single-backtick span breaks after
# line 1 and an inner line like "# not-a-heading" would render as a real
# heading in the posted comment. Multi-line evidence must go into a fenced
# code block instead, where every line renders verbatim.
echo "Test 6: multi-line evidence is fenced, not spliced into an inline span"
sess=$(mktemp -d); make_review_session "$sess"
jq '.verified[0].evidence = "if cfg.TLS {\n# not-a-heading\n}"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qE '^# ' "$sess/comment-body.md"; then
	echo "  PASS: no evidence line escaped as a real heading"; PASS=$((PASS+1))
else
	echo "  FAIL: evidence line rendered as a real markdown heading"; FAIL=$((FAIL+1))
fi
if grep -qF '```' "$sess/comment-body.md" && grep -qF '# not-a-heading' "$sess/comment-body.md"; then
	echo "  PASS: multi-line evidence rendered inside a fenced block"; PASS=$((PASS+1))
else
	echo "  FAIL: multi-line evidence not fenced"; FAIL=$((FAIL+1))
fi
opens=$(grep -cF "<details>" "$sess/comment-body.md"); closes=$(grep -cF "</details>" "$sess/comment-body.md")
if [[ "$opens" -eq "$closes" && "$opens" -ge 2 ]]; then
	echo "  PASS: details structure still well-formed ($opens/$closes)"; PASS=$((PASS+1))
else
	echo "  FAIL: details structure broken by multi-line evidence ($opens/$closes)"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 7: optional constraint field - rendered when present and non-empty,
# omitted entirely (no empty line) when absent.
echo "Test 7: constraint field rendered only when present"
sess=$(mktemp -d); make_review_session "$sess"
jq '.verified[0].constraint = "CR-042: no raw SQL interpolation"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF '  **Constraint:** CR-042: no raw SQL interpolation' "$sess/comment-body.md"; then
	echo "  PASS: constraint rendered when present"; PASS=$((PASS+1))
else
	echo "  FAIL: constraint missing when present"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

sess=$(mktemp -d); make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qF '**Constraint:**' "$sess/comment-body.md"; then
	echo "  PASS: no constraint line when field absent"; PASS=$((PASS+1))
else
	echo "  FAIL: empty constraint line leaked when field absent"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

# Test 8: forge-neutrality guard - a missing/unparseable origin host must leave
# RC_FORGE_WEB empty, never default to github.com. This renderer is documented
# as forge-NEUTRAL (header comment + forge-adapters.md); a github.com default
# here would mis-link a future GitLab poster. See rc-post-comment-github.sh for
# where the GitHub-specific default now lives.
echo "Test 8: missing origin leaves RC_FORGE_WEB empty (no github.com default)"
sess=$(mktemp -d); make_review_session "$sess" github 42 ""
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_url_file()   { printf '%s/blob/%s/%s#L%s' "$1" "$2" "$3" "$4"; }
	rc_url_commit() { printf '%s/commit/%s' "$1" "$2"; }
	rc_render_comment_body "$sess" "$sess/body.md"
	{ echo "$RC_FORGE_WEB"; } >"$sess/exports"
)
web=$(cat "$sess/exports")
if [[ -z "$web" ]]; then
	echo "  PASS: RC_FORGE_WEB empty when origin missing/unparseable"; PASS=$((PASS+1))
else
	echo "  FAIL: RC_FORGE_WEB defaulted to '$web'"; FAIL=$((FAIL+1))
fi
b8=$(cat "$sess/body.md")
# Note: the footer legitimately links to this project's own (GitHub-hosted)
# repo, so the assertion targets the reviewed-repo host (acme/widgets), not
# every "github.com" substring.
if ! grep -qF "https://github.com/acme/widgets" <<<"$b8"; then
	echo "  PASS: no defaulted github.com/acme/widgets URL leaked into body"; PASS=$((PASS+1))
else
	echo "  FAIL: github.com/acme/widgets leaked into rendered body"; FAIL=$((FAIL+1))
fi
if ! grep -qF "https:///" <<<"$b8"; then
	echo "  PASS: no broken https:/// URL"; PASS=$((PASS+1))
else
	echo "  FAIL: broken https:/// URL present"; FAIL=$((FAIL+1))
fi
if grep -qF '`auth/token.go:1`' <<<"$b8"; then
	echo "  PASS: finding degrades to plain code span"; PASS=$((PASS+1))
else
	echo "  FAIL: finding did not degrade to plain code span"; FAIL=$((FAIL+1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
