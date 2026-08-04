#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-render-comment.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Test 1: standalone render -> plain code spans (no hooks defined), full body
echo "Test 1: standalone render (plain spans)"
sess=$(mktemp -d)
make_review_session "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered"
body=$(cat "$sess/comment-body.md")
for needle in "Review Council: REQUEST CHANGES" "TL;DR" "Reviewed at commit" "(high effort)" "auth/token.go:1" "🛡️" "<!-- review-council:marker sha=" "Produced by [Review Council]" "💡 **Recommendation:**" "💬 Full reviewer analysis"; do
	if grep -qF "$needle" <<<"$body"; then
		echo "  PASS: contains '$needle'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: missing '$needle'"
		FAIL=$((FAIL + 1))
	fi
done
# plain mode: no forge deep-links
if ! grep -qF "/blob/" <<<"$body" && ! grep -qF "/commit/" <<<"$body"; then
	echo "  PASS: no deep-links in plain mode"
	PASS=$((PASS + 1))
else
	echo "  FAIL: deep-links leaked into plain mode"
	FAIL=$((FAIL + 1))
fi
# No em/en dashes. Matched with bash patterns rather than `! grep -qP`: BSD grep
# has no PCRE, and negating it reads an option error (exit 2) as "no match", so
# the assertion would pass on macOS precisely when the renderer was broken.
if [[ "$body" != *—* && "$body" != *–* ]]; then
	echo "  PASS: no em/en dashes"
	PASS=$((PASS + 1))
else
	echo "  FAIL: em/en dash present"
	FAIL=$((FAIL + 1))
fi
# Blank line between a finding title and the fence opening its evidence. Bash's
# =~ spans lines without needing GNU grep's -z, and uses only POSIX ERE
# constructs (a backtick is literal in an ERE).
nl=$'\n'
# shellcheck disable=SC2016 # literal markdown fence delimiter, not command substitution.
fence='```'
quote_re="\*\*The expiry check rejects tokens at the exact boundary\.\*\*[^${nl}]*${nl}${nl}  ${fence}"
if [[ "$body" =~ $quote_re ]]; then
	echo "  PASS: blank line before evidence fence"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no blank line before evidence fence"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 2: sourced render with stub hooks -> markdown deep-links + exports set
echo "Test 2: sourced render with hooks (deep-links + exports)"
sess=$(mktemp -d)
make_review_session "$sess"
cat >"$sess/models.json" <<'MJ'
[{"role":"divisor-adversary-code","id":"claude-opus-4-8"},{"role":"divisor-guard-code","id":"claude-opus-4-8"}]
MJ
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_url_file() { printf '%s/blob/%s/%s#L%s' "$1" "$2" "$3" "$4"; }
	rc_url_commit() { printf '%s/commit/%s' "$1" "$2"; }
	rc_render_comment_body "$sess" "$sess/body.md"
	{
		echo "$RC_FORGE_WEB"
		echo "$RC_SHORT_SHA"
		echo "$RC_HEAD_SHA"
	} >"$sess/exports"
)
b2=$(cat "$sess/body.md")
if grep -qF "https://github.example.com/acme/widgets/blob/" <<<"$b2" && grep -qF "#L1" <<<"$b2"; then
	echo "  PASS: finding deep-link built via rc_url_file"
	PASS=$((PASS + 1))
else
	echo "  FAIL: finding deep-link missing"
	FAIL=$((FAIL + 1))
fi
if grep -qF "https://github.example.com/acme/widgets/commit/" <<<"$b2"; then
	echo "  PASS: commit stamp link built via rc_url_commit"
	PASS=$((PASS + 1))
else
	echo "  FAIL: commit stamp link missing"
	FAIL=$((FAIL + 1))
fi
# two models.json entries share the same id -> deduped to a single bullet
model_mentions=$(grep -c 'claude-opus-4-8' <<<"$b2")
if grep -qF "> - claude-opus-4-8" <<<"$b2" && [[ "$model_mentions" -eq 1 ]]; then
	echo "  PASS: provenance bullet deduped"
	PASS=$((PASS + 1))
else
	echo "  FAIL: provenance bullets wrong"
	FAIL=$((FAIL + 1))
fi
web=$(sed -n 1p "$sess/exports")
short=$(sed -n 2p "$sess/exports")
full=$(sed -n 3p "$sess/exports")
if [[ "$web" == "https://github.example.com/acme/widgets" && -n "$short" && "${full:0:7}" == "$short" ]]; then
	echo "  PASS: exports RC_FORGE_WEB/RC_SHORT_SHA/RC_HEAD_SHA set"
	PASS=$((PASS + 1))
else
	echo "  FAIL: exports wrong (web='$web' short='$short' full='$full')"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 3: findings render deterministically from findings.json fields (no
# base64 detail blob, no awk re-segmentation) - recommendation and
# description are separate fields, rendered as-is.
echo "Test 3: deterministic field rendering (recommendation + analysis)"
sess=$(mktemp -d)
make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body=$(cat "$sess/comment-body.md")
if grep -qF "<details><summary>💬 Full reviewer analysis</summary>" <<<"$body"; then
	echo "  PASS: nested 💬 summary present"
	PASS=$((PASS + 1))
else
	echo "  FAIL: nested summary missing"
	FAIL=$((FAIL + 1))
fi
# Recommendation field renders verbatim, lightbulb-tagged, inline (single line).
# shellcheck disable=SC2016 # literal markdown code span in the expected output.
if grep -qF '  💡 **Recommendation:** Use `<=` so a token expiring exactly now is still valid.' "$sess/comment-body.md"; then
	echo "  PASS: recommendation field rendered verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: recommendation not rendered verbatim"
	FAIL=$((FAIL + 1))
fi
# Description field renders verbatim inside the collapsed analysis.
if grep -qF '  The expiry check rejects tokens at the exact boundary.' "$sess/comment-body.md"; then
	echo "  PASS: description rendered inside analysis"
	PASS=$((PASS + 1))
else
	echo "  FAIL: description missing from analysis"
	FAIL=$((FAIL + 1))
fi
# Recommendation renders ABOVE its Full reviewer analysis block.
rec_ln=$(grep -n '💡 \*\*Recommendation:\*\*' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
ana_ln=$(grep -n '💬 Full reviewer analysis' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
if [[ -n "$rec_ln" && -n "$ana_ln" && "$rec_ln" -lt "$ana_ln" ]]; then
	echo "  PASS: recommendation above full analysis ($rec_ln < $ana_ln)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: recommendation not above analysis (rec=$rec_ln ana=$ana_ln)"
	FAIL=$((FAIL + 1))
fi
# both details tags balance (2 open: severity + analysis; 2 close)
opens=$(grep -cF "<details>" "$sess/comment-body.md")
closes=$(grep -cF "</details>" "$sess/comment-body.md")
if [[ "$opens" -eq "$closes" && "$opens" -ge 2 ]]; then
	echo "  PASS: details tags balanced ($opens/$closes)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: details tags unbalanced ($opens/$closes)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 4: no title field -> falls back to first ~60 chars of description
echo "Test 4: title falls back to description prefix"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].title = null' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "**The expiry check rejects tokens at the exact boundary.**" "$sess/comment-body.md"; then
	echo "  PASS: title falls back to description prefix"
	PASS=$((PASS + 1))
else
	echo "  FAIL: title fallback not rendered"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 5: RC_BUGS #1/#2 guard - real-tab evidence and provenance.calibrated_from
# must never leak raw JSON-escape sequences or a calibration HTML comment into
# the posted body. Direct guard against the PR-114/115 @tsv + detail bleed:
# jq -r field access (never @tsv) means an embedded tab travels through as a
# real tab byte, not the two-character "\t" escape sequence, and provenance is
# never touched by the renderer at all.
echo "Test 5: tab evidence + calibration provenance does not bleed into body"
sess=$(mktemp -d)
make_review_session "$sess"
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
	echo "  PASS: no literal backslash-t escape sequence in body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: literal backslash-t escape leaked into body"
	FAIL=$((FAIL + 1))
fi
if ! grep -qF $'\\' "$sess/comment-body.md"; then
	echo "  PASS: no stray backslash literal in body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: stray backslash literal leaked into body"
	FAIL=$((FAIL + 1))
fi
rendered_body=$(cat "$sess/comment-body.md")
if [[ "$rendered_body" == *$'\tif cfg.TLS {'* ]]; then
	echo "  PASS: real tab byte from evidence preserved"
	PASS=$((PASS + 1))
else
	echo "  FAIL: real tab byte from evidence missing"
	FAIL=$((FAIL + 1))
fi
if ! grep -qi "calibrat" "$sess/comment-body.md"; then
	echo "  PASS: no calibration HTML comment leaked"
	PASS=$((PASS + 1))
else
	echo "  FAIL: calibration provenance leaked into body"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Guard cfg.TLS before dereferencing it." "$sess/comment-body.md"; then
	echo "  PASS: recommendation text present"
	PASS=$((PASS + 1))
else
	echo "  FAIL: recommendation text missing"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 6: multi-line evidence must not bleed into the surrounding markdown
# structure. evidence is schema-permitted to be multi-line; jq -r turns its
# JSON \n into real newlines, so a naive single-backtick span breaks after
# line 1 and an inner line like "# not-a-heading" would render as a real
# heading in the posted comment. Multi-line evidence must go into a fenced
# code block instead, where every line renders verbatim.
echo "Test 6: multi-line evidence is fenced, not spliced into an inline span"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].evidence = "if cfg.TLS {\n# not-a-heading\n}"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qE '^# ' "$sess/comment-body.md"; then
	echo "  PASS: no evidence line escaped as a real heading"
	PASS=$((PASS + 1))
else
	echo "  FAIL: evidence line rendered as a real markdown heading"
	FAIL=$((FAIL + 1))
fi
if grep -qF '```' "$sess/comment-body.md" && grep -qF '# not-a-heading' "$sess/comment-body.md"; then
	echo "  PASS: multi-line evidence rendered inside a fenced block"
	PASS=$((PASS + 1))
else
	echo "  FAIL: multi-line evidence not fenced"
	FAIL=$((FAIL + 1))
fi
opens=$(grep -cF "<details>" "$sess/comment-body.md")
closes=$(grep -cF "</details>" "$sess/comment-body.md")
if [[ "$opens" -eq "$closes" && "$opens" -ge 2 ]]; then
	echo "  PASS: details structure still well-formed ($opens/$closes)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: details structure broken by multi-line evidence ($opens/$closes)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 7: optional constraint field - rendered when present and non-empty,
# omitted entirely (no empty line) when absent.
echo "Test 7: constraint field rendered only when present"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].constraint = "CR-042: no raw SQL interpolation"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF '  **Constraint:** CR-042: no raw SQL interpolation' "$sess/comment-body.md"; then
	echo "  PASS: constraint rendered when present"
	PASS=$((PASS + 1))
else
	echo "  FAIL: constraint missing when present"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

sess=$(mktemp -d)
make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if ! grep -qF '**Constraint:**' "$sess/comment-body.md"; then
	echo "  PASS: no constraint line when field absent"
	PASS=$((PASS + 1))
else
	echo "  FAIL: empty constraint line leaked when field absent"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 8: forge-neutrality guard - a missing/unparseable origin host must leave
# RC_FORGE_WEB empty, never default to github.com. This renderer is documented
# as forge-NEUTRAL (header comment + forge-adapters.md); a github.com default
# here would mis-link a future GitLab poster. See rc-post-comment-github.sh for
# where the GitHub-specific default now lives.
echo "Test 8: missing origin leaves RC_FORGE_WEB empty (no github.com default)"
sess=$(mktemp -d)
make_review_session "$sess" github 42 ""
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_url_file() { printf '%s/blob/%s/%s#L%s' "$1" "$2" "$3" "$4"; }
	rc_url_commit() { printf '%s/commit/%s' "$1" "$2"; }
	rc_render_comment_body "$sess" "$sess/body.md"
	{ echo "$RC_FORGE_WEB"; } >"$sess/exports"
)
web=$(cat "$sess/exports")
if [[ -z "$web" ]]; then
	echo "  PASS: RC_FORGE_WEB empty when origin missing/unparseable"
	PASS=$((PASS + 1))
else
	echo "  FAIL: RC_FORGE_WEB defaulted to '$web'"
	FAIL=$((FAIL + 1))
fi
b8=$(cat "$sess/body.md")
# Note: the footer legitimately links to this project's own (GitHub-hosted)
# repo, so the assertion targets the reviewed-repo host (acme/widgets), not
# every "github.com" substring.
if ! grep -qF "https://github.com/acme/widgets" <<<"$b8"; then
	echo "  PASS: no defaulted github.com/acme/widgets URL leaked into body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: github.com/acme/widgets leaked into rendered body"
	FAIL=$((FAIL + 1))
fi
if ! grep -qF "https:///" <<<"$b8"; then
	echo "  PASS: no broken https:/// URL"
	PASS=$((PASS + 1))
else
	echo "  FAIL: broken https:/// URL present"
	FAIL=$((FAIL + 1))
fi
# shellcheck disable=SC2016 # literal markdown code span in the expected output.
if grep -qF '`auth/token.go:1`' <<<"$b8"; then
	echo "  PASS: finding degrades to plain code span"
	PASS=$((PASS + 1))
else
	echo "  FAIL: finding did not degrade to plain code span"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 9: evidence carrying its own backticks must not break out of its block.
# A fixed three-backtick fence is closed by any evidence line that is itself a
# three-backtick fence -- two spaces of list indent is still <= 3, so it stays a
# valid CommonMark closing fence. The rest of the evidence then escapes as live
# markdown and the trailing delimiter opens an UNTERMINATED fence that swallows
# every later finding, the footer and the <!-- review-council:marker --> line the
# re-review upsert matches on. Evidence is verbatim content from the changeset,
# so its author controls those bytes. The fence is therefore sized to the
# content: one backtick wider than the longest run inside the evidence.
echo "Test 9: evidence fence is sized to the evidence, never fixed at three"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].evidence = "line one\n```\nline three"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
open4=$(grep -cFx '  ````' "$sess/comment-body.md" || true)
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
inner3=$(grep -cFx '  ```' "$sess/comment-body.md" || true)
if [[ "$open4" -eq 2 ]]; then
	echo "  PASS: three-backtick evidence fenced with four backticks"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 2 four-backtick fence lines, got $open4"
	FAIL=$((FAIL + 1))
fi
if [[ "$inner3" -eq 1 ]]; then
	echo "  PASS: the evidence's own fence line is content, not a delimiter"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 1 three-backtick line (evidence), got $inner3"
	FAIL=$((FAIL + 1))
fi
# The line after the evidence's own fence must still sit BETWEEN the block's own
# two delimiters -- presence alone proves nothing, since the broken rendering
# also left the text in the file, just outside the code block.
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
open_ln=$(grep -nFx '  ````' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
close_ln=$(grep -nFx '  ````' "$sess/comment-body.md" | tail -1 | cut -d: -f1 || true)
three_ln=$(grep -nFx '  line three' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
if [[ -n "$open_ln" && -n "$close_ln" && -n "$three_ln" && "$three_ln" -gt "$open_ln" && "$three_ln" -lt "$close_ln" ]]; then
	echo "  PASS: evidence after the inner fence stayed inside the block"
	PASS=$((PASS + 1))
else
	echo "  FAIL: evidence after the inner fence escaped the block (open=$open_ln line=$three_ln close=$close_ln)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Single-line evidence takes the same sized fence. It used to render as an
# inline `> `code span``, which any backtick in the quoted source terminates --
# and a backtick in a cited shell or markdown line is routine, not exotic.
sess=$(mktemp -d)
make_review_session "$sess"
# shellcheck disable=SC2016 # literal backticks inside the jq program's JSON string.
jq '.verified[0].evidence = "# Run `make test` before pushing."' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
span3=$(grep -cFx '  ```' "$sess/comment-body.md" || true)
if [[ "$span3" -eq 2 ]]; then
	echo "  PASS: single-line evidence fenced (minimum three backticks)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 2 three-backtick fence lines, got $span3"
	FAIL=$((FAIL + 1))
fi
# shellcheck disable=SC2016 # literal markdown code span in the rejected output.
if ! grep -qF '  > `' "$sess/comment-body.md"; then
	echo "  PASS: no inline code span a backtick could terminate"
	PASS=$((PASS + 1))
else
	echo "  FAIL: single-line evidence still rendered as an inline code span"
	FAIL=$((FAIL + 1))
fi
# shellcheck disable=SC2016 # literal backticks quoted from the evidence.
if grep -qFx '  # Run `make test` before pushing.' "$sess/comment-body.md"; then
	echo "  PASS: backticked evidence preserved verbatim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: backticked evidence not preserved verbatim"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Four-backtick evidence proves the width is computed from the content rather
# than bumped to a hardcoded four.
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].evidence = "line one\n````\nline three"' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
open5=$(grep -cFx '  `````' "$sess/comment-body.md" || true)
# shellcheck disable=SC2016 # literal markdown fence delimiters, not command substitution.
inner4=$(grep -cFx '  ````' "$sess/comment-body.md" || true)
if [[ "$open5" -eq 2 && "$inner4" -eq 1 ]]; then
	echo "  PASS: four-backtick evidence fenced with five backticks"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 2 five-backtick fences and 1 four-backtick line, got $open5/$inner4"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 10: the house-style dash rewrite is a prose edit, so it must run on the
# LLM-authored fields only. Filtering the whole assembled body rewrote bytes
# inside the evidence block, breaking the byte-for-byte contract
# reviewer-protocol.md places on evidence and making the same finding's evidence
# differ between the posted comment and the rendered report.
echo "Test 10: dash normalisation spares evidence, still cleans reviewer prose"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].evidence = "flags := \"--strict\" — legacy" |
    .verified[0].description = "The flag list carries a smart dash — it should be a hyphen." |
    .verified[0].recommendation = "Replace the dash — use ASCII." |
    .verified[0].title = "Smart dash — in a flag list" |
    .verified[0].constraint = "STYLE-7: ASCII punctuation only – no en dashes"' \
	"$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
echo "One finding — a smart dash in a flag list." >"$sess/comment-summary.md"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body=$(cat "$sess/comment-body.md")
if [[ "$body" == *'flags := "--strict" — legacy'* ]]; then
	echo "  PASS: em dash inside evidence survives byte-for-byte"
	PASS=$((PASS + 1))
else
	echo "  FAIL: em dash inside evidence was rewritten"
	FAIL=$((FAIL + 1))
fi
for prose in \
	"The flag list carries a smart dash - it should be a hyphen." \
	"Replace the dash - use ASCII." \
	"Smart dash - in a flag list" \
	"STYLE-7: ASCII punctuation only - no en dashes" \
	"One finding - a smart dash in a flag list."; do
	if grep -qF "$prose" <<<"$body"; then
		echo "  PASS: normalised prose '$prose'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: prose not normalised '$prose'"
		FAIL=$((FAIL + 1))
	fi
done
# Exactly one em dash left in the whole body: the one quoted inside evidence.
dashes=${body//[!—]/}
if [[ "${#dashes}" -eq 1 && "$body" != *–* ]]; then
	echo "  PASS: the only em/en dash left is the evidence quote"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 1 em dash (evidence) and no en dash, got ${#dashes} em dashes"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
