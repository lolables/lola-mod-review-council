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
quote_re="\*\*The expiry check rejects tokens at the exact boundary\*\*[^${nl}]*${nl}${nl}  ${fence}"
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

# Test 4: no title field -> falls back to the description's FIRST SENTENCE.
# This used to assert a 60-byte prefix, which was not a fallback in practice:
# `title` was absent from verdict-schema.json and additionalProperties:false
# rejected any verdict carrying one, so every headline in every artifact was
# that mid-word cut. The fixture's second sentence is what makes the boundary
# observable — a single-sentence description would pass either way.
echo "Test 4: title falls back to the description's first sentence"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].title = null' "$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "**The expiry check rejects tokens at the exact boundary**" "$sess/comment-body.md"; then
	echo "  PASS: headline is the first sentence, terminal period dropped"
	PASS=$((PASS + 1))
else
	echo "  FAIL: first-sentence fallback not rendered"
	FAIL=$((FAIL + 1))
fi
if grep -qF "logged out without warning.**" "$sess/comment-body.md"; then
	echo "  FAIL: the headline swallowed the second sentence too"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: the headline stops at the sentence boundary"
	PASS=$((PASS + 1))
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

echo "Test 6b: tabs and newlines in several fields at once stay in their own field"
# rc_finding_block reads all of a finding's fields out of jq in one call, framed
# on NUL, rather than spawning one jq per field. Framing is the risk that buys:
# a separator that can occur inside a value splices two fields together, and the
# damage shows up as prose appearing under the wrong label rather than as an
# error. Tabs and newlines are exactly what the fields carry — evidence is
# source code — so they are the separators that must not be used, and this puts
# them in four fields at once. NUL is safe because bash cannot hold one in a
# variable at all: `$(...)` discards it, so the per-field form could not carry
# one either.
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified[0].evidence = "if a\t< b {\n\tpanic()\n}" |
    .verified[0].description = "Tab\there.\nNewline there." |
    .verified[0].recommendation = "Use\t<= instead.\nSecond line." |
    .verified[0].title = "Tabbed\ttitle" |
    .verified[0].constraint = "STYLE-9:\tno raw tabs"' \
	"$sess/verdicts/findings.json" >"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body=$(cat "$sess/comment-body.md")
# Each field is checked for a fragment that only it carries. A framing slip
# concatenates neighbours, so the victim field loses its own opening text.
for probe in \
	"Tabbed	title" \
	"Newline there." \
	"Use	<= instead." \
	"STYLE-9:	no raw tabs"; do
	if grep -qF "$probe" <<<"$body"; then
		echo "  PASS: field kept its own content ('${probe%%$'\t'*}…')"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: field lost or merged ('${probe%%$'\t'*}…')"
		FAIL=$((FAIL + 1))
	fi
done
# The recommendation label must be followed by the recommendation, not by
# whatever a slipped separator dragged in front of it.
if grep -qF 'Recommendation:** Use' <<<"$body"; then
	echo "  PASS: recommendation label is followed by the recommendation"
	PASS=$((PASS + 1))
else
	echo "  FAIL: recommendation label is followed by another field's text"
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

echo "Test: a title-less finding is headlined by its first sentence, not 60 bytes"
# .title was unreachable until the schema gained it, so this is the path every
# finding took: a hard 60-byte cut, mid-word, with no ellipsis.
sess=$(mktemp -d)
make_review_session "$sess"
cat >"$sess/verdicts/findings.json" <<'FJ'
{"verified":[
 {"agent":"divisor-adversary-code","severity":"HIGH","file":"auth/token.go","line":42,
  "evidence":"if exp < now {",
  "description":"Tokens expiring at exactly the current instant are rejected. A client that refreshes on the boundary is logged out without warning.",
  "recommendation":"Compare with <= so a token expiring exactly now is still accepted.",
  "status":"verified","verdict":"REQUEST CHANGES","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":1,"duplicates_consolidated":0,
 "verdicts":{"divisor-adversary-code":"REQUEST CHANGES"}}
FJ
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body="$sess/comment-body.md"
if grep -qE '\*\*Tokens expiring at exactly the current instant are rej\*\*' "$body"; then
	echo "  FAIL: headline is still cut at 60 bytes, mid-sentence"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no 60-byte cut"
	PASS=$((PASS + 1))
fi
if grep -qF '**Tokens expiring at exactly the current instant are rejected**' "$body"; then
	echo "  PASS: headline is the first sentence, ending where the author ended it"
	PASS=$((PASS + 1))
else
	echo "  FAIL: headline is not the first sentence"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: a supplied title is used verbatim"
sess=$(mktemp -d)
make_review_session "$sess"
cat >"$sess/verdicts/findings.json" <<'FJ'
{"verified":[
 {"agent":"divisor-adversary-code","severity":"HIGH","file":"auth/token.go","line":42,
  "title":"Expiry check rejects boundary tokens",
  "evidence":"if exp < now {",
  "description":"Tokens expiring at exactly the current instant are rejected, so a client that refreshes on the boundary is logged out.",
  "recommendation":"Use <=.","status":"verified","verdict":"REQUEST CHANGES","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":1,"duplicates_consolidated":0,
 "verdicts":{"divisor-adversary-code":"REQUEST CHANGES"}}
FJ
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF '**Expiry check rejects boundary tokens**' "$sess/comment-body.md"; then
	echo "  PASS: the reviewer's own headline is used"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a supplied title was ignored"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: the analysis details is omitted when it would only repeat the headline"
# A single-sentence description IS its own headline. Rendering it twice, once
# collapsed, is noise dressed as structure.
sess=$(mktemp -d)
make_review_session "$sess"
cat >"$sess/verdicts/findings.json" <<'FJ'
{"verified":[
 {"agent":"divisor-adversary-code","severity":"HIGH","file":"auth/token.go","line":42,
  "evidence":"if exp < now {","description":"Expired tokens are accepted at the boundary.",
  "recommendation":"Use <=.","status":"verified","verdict":"REQUEST CHANGES","provenance":{}}
],"correctable":[],"stripped":[],"total_findings":1,"duplicates_consolidated":0,
 "verdicts":{"divisor-adversary-code":"REQUEST CHANGES"}}
FJ
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF 'Full reviewer analysis' "$sess/comment-body.md"; then
	echo "  FAIL: a details block was rendered that only repeats the headline"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no redundant analysis block"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

# --- Paring ladder -----------------------------------------------------------
#
# The renderer is the last place that can keep a comment postable. Everything
# below asserts one half of the same contract: a body that fits the forge limit,
# and a reader who can tell that it was trimmed.

# Byte length, not character length. `${#var}` counts characters in a UTF-8
# locale and bytes in C, so it disagrees with itself across hosts; the renderer
# measures bytes for the same reason the assertions do.
body_bytes() { # file
	wc -c <"$1" | tr -d ' '
}

echo "Test: the reviewer table starts its own block"
# A markdown table has to begin a block. Run onto the end of the findings-count
# paragraph it is not a table, it is four lines of pipe characters -- and the
# ladder refactor broke exactly this, because `$(...)` strips the trailing
# newline that made the blank line. Pinned by content rather than by line
# number so it survives the header growing.
sess=$(mktemp -d)
make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
counts_ln=$(grep -n '^\*\*Findings:\*\*' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
after_counts=$(sed -n "$((counts_ln + 1))p" "$sess/comment-body.md")
if [[ -n "$counts_ln" && -z "$after_counts" ]]; then
	echo "  PASS: a blank line follows the findings counts"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the counts line runs straight into '${after_counts}'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: the disclosure line starts its own block too"
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '20000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
disc_ln=$(grep -n '^_Trimmed to fit the ' "$sess/comment-body.md" | head -1 | cut -d: -f1 || true)
before_disc=$(sed -n "$((disc_ln - 1))p" "$sess/comment-body.md")
after_disc=$(sed -n "$((disc_ln + 1))p" "$sess/comment-body.md")
if [[ -n "$disc_ln" && -z "$before_disc" && -z "$after_disc" ]]; then
	echo "  PASS: the disclosure is a paragraph of its own"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the disclosure is glued to '${before_disc}' / '${after_disc}'"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: no declared limit renders at full fidelity"
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
full_len=$(body_bytes "$sess/comment-body.md")
analysis_blocks=$(grep -cF "💬 Full reviewer analysis" "$sess/comment-body.md")
assert_equals "$analysis_blocks" "30" "every finding keeps its analysis with no limit"
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  FAIL: an unlimited render claimed to be trimmed"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no disclosure line when nothing was trimmed"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo "Test: a limit above the body length leaves it unpared"
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '1000000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
unpared_len=$(body_bytes "$sess/comment-body.md")
assert_equals "$unpared_len" "$full_len" \
	"a GitLab-shaped limit renders byte-identically to no limit"
rm -rf "$sess"

echo "Test: a tight limit pares the body under it and says so"
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '20000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
pared_len=$(body_bytes "$sess/comment-body.md")
if [[ "$pared_len" -le 20000 ]]; then
	echo "  PASS: pared body fits the declared limit ($pared_len <= 20000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: body overflows the declared limit ($pared_len > 20000)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  PASS: pared body carries the disclosure line"
	PASS=$((PASS + 1))
else
	echo "  FAIL: pared body is silently incomplete"
	FAIL=$((FAIL + 1))
fi
# Evidence is what makes a finding checkable, and it is what rc-verify-evidence
# matched byte-for-byte. Analysis prose goes first, always.
if grep -qF "subtle.ConstantTimeCompare" "$sess/comment-body.md"; then
	echo "  PASS: CRITICAL recommendation survives paring"
	PASS=$((PASS + 1))
else
	echo "  FAIL: CRITICAL recommendation was pared"
	FAIL=$((FAIL + 1))
fi
if grep -qF "The comparison uses the == operator" "$sess/comment-body.md"; then
	echo "  PASS: CRITICAL analysis survives paring"
	PASS=$((PASS + 1))
else
	echo "  FAIL: CRITICAL analysis was dropped"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: the ladder sheds the lowest severity first"
# Sized to land on level 1: LOW analysis gone, HIGH and MEDIUM analysis intact.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '%s' "$((full_len - 400))"; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
if ! grep -qF "The exported symbol carries no doc comment" "$sess/comment-body.md"; then
	echo "  PASS: LOW analysis is shed first"
	PASS=$((PASS + 1))
else
	echo "  FAIL: LOW analysis survived a level-1 pare"
	FAIL=$((FAIL + 1))
fi
if grep -qF "The deferred Close is called without inspecting" "$sess/comment-body.md" &&
	grep -qF "The loop retries until the call succeeds" "$sess/comment-body.md"; then
	echo "  PASS: MEDIUM and HIGH analysis untouched at level 1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the ladder skipped past level 1"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: the terminal case never emits an over-limit body"
# Far below what 30 findings can occupy at any level: this is the case the
# ladder exists to have a defined answer for.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '3000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
term_len=$(body_bytes "$sess/comment-body.md")
if [[ "$term_len" -le 3000 ]]; then
	echo "  PASS: terminal body fits ($term_len <= 3000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: terminal body overflows ($term_len > 3000)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the" "$sess/comment-body.md" &&
	grep -qF "omitted entirely" "$sess/comment-body.md"; then
	echo "  PASS: dropped findings are disclosed by count"
	PASS=$((PASS + 1))
else
	echo "  FAIL: findings vanished without disclosure"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: a cut body still carries its marker and its disclosure"
# Below roughly 1,240 bytes not even the verdict header with every finding
# already gone fits, so the ladder runs out and the body is cut at a line
# boundary. `Comment limit: 500` is valid configuration, so this is reachable
# from tracking.md, not just from a hostile hook.
#
# The cut takes the tail, and both things that make the comment honest live
# there or past it. The marker is the last line of every part and the only
# thing the poster's listings select on: a part that loses it is invisible to
# the next run, which posts a fresh comment beside the orphan and supersedes
# nothing, once more on every run after that. The disclosure is what stops the
# result reading as a complete review -- a body announcing 30 findings, showing
# none and claiming nothing was trimmed is the failure the ladder's own
# doctrine calls worse than an overflow error.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '600'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
cut_len=$(body_bytes "$sess/comment-body.md")
if [[ "$cut_len" -gt 0 && "$cut_len" -le 600 ]]; then
	echo "  PASS: cut body is non-empty and fits ($cut_len <= 600)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: cut body is empty or overflows ($cut_len)"
	FAIL=$((FAIL + 1))
fi
# Anchored at column 0 and spelled out in full: the listings bind the last line
# that STARTS with the marker opening, so a marker indented or run onto the end
# of a kept line would not be found.
if grep -qE '^<!-- review-council:marker sha=[^ ]+ part=1 of=1 -->$' "$sess/comment-body.md"; then
	echo "  PASS: the marker line survives the cut"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the cut discarded the marker, orphaning the comment"
	FAIL=$((FAIL + 1))
fi
# Last line, not merely present. The listing takes the LAST line opening a
# marker, and the anti-impersonation argument rests on a counterfeit quoted in
# evidence always sitting ABOVE the real one. A marker re-appended anywhere but
# the end satisfies the grep above and breaks both.
cut_last=$(tail -n 1 "$sess/comment-body.md")
if [[ "$cut_last" == "<!-- review-council:marker sha="* ]]; then
	echo "  PASS: the marker is the last line of the cut body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the marker is not the last line, so evidence can sit below it"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  PASS: the cut body still says it was trimmed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the cut body reads as a complete review of 30 findings"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: under the disclosure and marker the cut keeps only those"
# The documented floor. Below their combined length nothing readable fits under
# any policy, so the cut keeps identity and honesty and overshoots the limit --
# which nothing rejects, because the limit is the user's `Comment limit` and no
# poster measures a body against it. Pinned as an exact shape so a later "clamp
# the body to the limit" edit cannot quietly re-orphan the comment.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '50'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
floor_lines=$(wc -l <"$sess/comment-body.md" | tr -d ' ')
floor_first=$(sed -n 1p "$sess/comment-body.md")
floor_blank=$(sed -n 2p "$sess/comment-body.md")
floor_last=$(tail -n 1 "$sess/comment-body.md")
if [[ "$floor_lines" -eq 3 && "$floor_first" == "_Trimmed to fit the "* && -z "$floor_blank" &&
	"$floor_last" == "<!-- review-council:marker sha="* ]]; then
	echo "  PASS: the floor body is the disclosure and the marker, nothing else"
	PASS=$((PASS + 1))
else
	echo "  FAIL: floor body is not disclosure + marker (${floor_lines} lines, first '${floor_first}')"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: a cut deep enough to keep the disclosure is not handed a second"
# The disclosure is reserved and re-appended, and it also sits near the top of
# the body being cut. Above roughly 900 the fill reaches it, so without the
# containment check the reader is told twice.
#
# 785 is the harder half of the same case and the reason the check matches the
# disclosure's TEXT LINE: at that budget the fill stops between the disclosure
# and the blank line under it, so the body holds a disclosure that is not the
# reserved string. Found by rendering every limit from 1 to 1400 and counting,
# which is too slow to keep in this suite; the limits below are the shapes that
# scan turned up.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
for dup_limit in 785 900 1100 1239; do
	(
		# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
		source "$SCRIPT"
		eval "rc_comment_limit() { printf '%s' '$dup_limit'; }"
		rc_render_comment_body "$sess" "$sess/comment-body.md"
	)
	dup_disc=$(grep -c '^_Trimmed to fit the ' "$sess/comment-body.md" || true)
	dup_marker=$(grep -c '^<!-- review-council:marker sha=' "$sess/comment-body.md" || true)
	assert_equals "$dup_disc" "1" "limit ${dup_limit} discloses exactly once"
	assert_equals "$dup_marker" "1" "limit ${dup_limit} carries exactly one marker"
done
rm -rf "$sess"

echo "Test: a second render in one process reads the second findings set"
# Rendered blocks are memoised on (finding index, variant) to keep the ladder
# affordable, and the key carries nothing about which findings.json was loaded.
# A cache surviving the load would hand session A's block to session B under the
# same key, and the mismatch is silent: byte accounting, ladder and disclosure
# would all be internally consistent with the wrong content.
#
# Neither session records a `Comment limit`, so both settle on level 0 and the
# keys collide, which is what makes the staleness observable. A limit added to
# the shared fixture that pushed the two renders to different levels would give
# them different variants, different keys, and a test that passes vacuously.
sess=$(mktemp -d)
sess_b=$(mktemp -d)
make_review_session "$sess"
make_review_session "$sess_b"
jq '.verified[0].title = "Nonce is reused across requests" |
    .verified[0].file = "crypto/seal.go" |
    .verified[0].evidence = "nonce := staticNonce" |
    .verified[0].description = "The nonce is a package-level constant, so every request seals with the same value. Reusing it voids the confidentiality guarantee the cipher makes." |
    .verified[0].recommendation = "Draw a fresh nonce per request."' \
	"$sess_b/verdicts/findings.json" >"$sess_b/verdicts/fj.tmp" &&
	mv "$sess_b/verdicts/fj.tmp" "$sess_b/verdicts/findings.json"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_render_comment_body "$sess" "$sess/comment-body.md"
	rc_render_comment_body "$sess_b" "$sess_b/comment-body.md"
)
if grep -qF "**Nonce is reused across requests**" "$sess_b/comment-body.md"; then
	echo "  PASS: the second body carries the second session's finding"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the second body is missing the second session's finding"
	FAIL=$((FAIL + 1))
fi
if grep -qF "The expiry check rejects tokens at the exact boundary" "$sess_b/comment-body.md"; then
	echo "  FAIL: the second body served the first session's cached block"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no block from the first session leaked into the second"
	PASS=$((PASS + 1))
fi
rm -rf "$sess" "$sess_b"

echo "Test: the limit is read from tracking.md on the standalone path"
# rc_comment_limit is a shell function and cannot cross the process boundary the
# router's `exec` creates, so the resolved numbers travel through tracking.md.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Comment limit: 20000\n' >>"$sess/tracking.md"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
standalone_len=$(body_bytes "$sess/comment-body.md")
if [[ "$standalone_len" -le 20000 ]]; then
	echo "  PASS: standalone render honours the recorded limit ($standalone_len <= 20000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: standalone render ignored the recorded limit ($standalone_len > 20000)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: a recorded limit overrides the forge hook"
# The override exists for self-hosted GitLab and GHE behind a proxy that
# imposes a smaller body than the forge itself does.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Comment limit: 20000\n' >>"$sess/tracking.md"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '1000000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
override_len=$(body_bytes "$sess/comment-body.md")
if [[ "$override_len" -le 20000 ]]; then
	echo "  PASS: the recorded limit wins over the hook ($override_len <= 20000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the hook overrode the user's recorded limit ($override_len > 20000)"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: evidence and recommendation outlive the analysis prose"
# The stated ordering invariant, and the one worth pinning hardest: evidence is
# what makes a finding checkable, and it is what rc-verify-evidence.sh matched
# byte-for-byte. A ladder that shed it first would still fit the limit and still
# disclose - and would still be wrong.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '20000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
med_analysis=$(grep -cF "The deferred Close is called without inspecting" "$sess/comment-body.md" || true)
med_evidence=$(grep -cF "defer f.Close()" "$sess/comment-body.md" || true)
med_rec=$(grep -cF "closeWithErr pattern in this package" "$sess/comment-body.md" || true)
assert_equals "$med_analysis" "0" "MEDIUM analysis is what the level sheds"
assert_equals "$med_evidence" "16" "every MEDIUM finding keeps its evidence"
assert_equals "$med_rec" "16" "every MEDIUM finding keeps its recommendation"
rm -rf "$sess"

echo "Test: collapsing a finding is not losing it"
# Levels 3 and 5 collapse findings to a headline; they do not drop them. A
# regression that dropped instead of collapsing would shrink the body just as
# effectively and report the same level, so the count is the only thing that
# tells them apart.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '8000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
	printf '%s %s\n' "$RC_COMMENT_LEVEL" "$RC_COMMENT_DROPPED" >"$sess/result"
)
read -r collapse_level collapse_dropped <"$sess/result"
assert_equals "$collapse_dropped" "0" "a collapse level drops no findings"
if [[ "$collapse_level" -ge 3 ]]; then
	echo "  PASS: reached a collapse level ($collapse_level)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected level 3 or higher, got $collapse_level"
	FAIL=$((FAIL + 1))
fi
assert_equals "$(grep -cF "(case " "$sess/comment-body.md" || true)" "30" \
	"all 30 findings still listed after collapsing"
rm -rf "$sess"

echo "Test: an unsplit verdict still declares its place in the chain"
# part=1 of=1 rather than a bare marker: the poster's per-part matching reads
# these, so the single-comment case has to speak the same grammar.
sess=$(mktemp -d)
make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "part=1 of=1 -->" "$sess/comment-body.md"; then
	echo "  PASS: single-comment marker carries part=1 of=1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: single-comment marker is missing part/of"
	FAIL=$((FAIL + 1))
fi
if grep -qF "review-council:part-links" "$sess/comment-body.md"; then
	echo "  FAIL: an unsplit verdict carries a part-link placeholder"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no part-link placeholder when there is nothing to link to"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

# --- Limit resolution: the values that must NOT be honoured -------------------
#
# A limit is a positive character count. Every other shape has to fall through
# to the next source rather than be taken literally, because taking it literally
# is how a body gets pared to nothing.

# Render with <tracking-lines> appended and an optional hook, and print
# "<resolved-limit> <level> <bytes>".
#
# hook_value is `none` for "define no rc_comment_limit at all"; every other
# value, the empty string included, defines a hook returning it. Keying "define
# nothing" on emptiness instead would make the empty-hook case -- a forge
# adapter that declares the hook and returns nothing, which is a different
# branch of the renderer's resolution -- unreachable from here.
render_with_limit() { # session tracking_lines hook_value
	local s="$1"
	[[ -z "$2" ]] || printf '%b' "$2" >>"$s/tracking.md"
	(
		# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
		source "$SCRIPT"
		if [[ "$3" != "none" ]]; then
			eval "rc_comment_limit() { printf '%s' '$3'; }"
		fi
		rc_render_comment_body "$s" "$s/comment-body.md"
		local bytes
		bytes=$(wc -c <"$s/comment-body.md")
		printf '%s %s %s\n' "$RC_COMMENT_LIMIT" "$RC_COMMENT_LEVEL" "$bytes"
	)
}

echo "Test: a recorded limit that is not a positive integer defers to the forge"
for bad in "forge default" "abc" "-500" "0" "20 000" "65536.0"; do
	sess=$(mktemp -d)
	make_review_session "$sess"
	make_review_session_many "$sess"
	limit_probe=$(render_with_limit "$sess" "- Comment limit: ${bad}\n" "20000")
	read -r got_limit got_level got_bytes <<<"$limit_probe"
	if [[ "$got_limit" == "20000" && "$got_bytes" -gt 0 && "$got_bytes" -le 20000 ]]; then
		echo "  PASS: '${bad}' fell through to the hook (limit=$got_limit level=$got_level)"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: '${bad}' was honoured as a limit (limit=$got_limit bytes=$got_bytes)"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$sess"
done

echo "Test: a forge hook that returns nonsense means no limit, not a zero one"
# A hook is code someone else wrote. Returning an empty string, a word, or zero
# has to read as "this adapter declares no limit" - never as "trim everything".
for bad in "" "unlimited" "0" "-1"; do
	sess=$(mktemp -d)
	make_review_session "$sess"
	make_review_session_many "$sess"
	limit_probe=$(render_with_limit "$sess" "" "$bad")
	read -r got_limit got_level got_bytes <<<"$limit_probe"
	if [[ "$got_level" -eq 0 && "$got_bytes" -eq "$full_len" ]]; then
		echo "  PASS: hook value '${bad}' left the body at full fidelity"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: hook value '${bad}' pared the body (limit=$got_limit level=$got_level bytes=$got_bytes)"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$sess"
done

echo "Test: a recorded Max comments that is not a positive integer means one"
for bad in "abc" "0" "-3"; do
	sess=$(mktemp -d)
	make_review_session "$sess"
	make_review_session_many "$sess"
	limit_probe=$(render_with_limit "$sess" "- Comment limit: 12000\n- Max comments: ${bad}\n" "none")
	read -r _ bad_level _ <<<"$limit_probe"
	(
		# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
		source "$SCRIPT"
		rc_render_comment_body "$sess" "$sess/comment-body.md"
		printf '%s\n' "$RC_COMMENT_PARTS" >"$sess/parts"
	)
	bad_parts=$(cat "$sess/parts")
	if [[ "$bad_parts" -eq 1 && "$bad_level" -gt 0 ]]; then
		echo "  PASS: Max comments '${bad}' fell back to 1, so the ladder ran instead"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: Max comments '${bad}' was honoured (parts=$bad_parts level=$bad_level)"
		FAIL=$((FAIL + 1))
	fi
	rm -rf "$sess"
done

echo "Test: a session with no findings renders a verdict, not an empty file"
sess=$(mktemp -d)
make_review_session "$sess"
jq '.verified = [] | .verdicts = {} | .total_findings = 0' "$sess/verdicts/findings.json" \
	>"$sess/verdicts/fj.tmp" && mv "$sess/verdicts/fj.tmp" "$sess/verdicts/findings.json"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '65536'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
empty_bytes=$(body_bytes "$sess/comment-body.md")
if [[ "$empty_bytes" -gt 0 ]] && grep -qF "Review Council:" "$sess/comment-body.md"; then
	echo "  PASS: a findings-free review still posts its verdict ($empty_bytes bytes)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no findings produced no body ($empty_bytes bytes)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  FAIL: a findings-free review claimed to be trimmed"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: nothing to trim, nothing claimed"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

# --- Comment chaining --------------------------------------------------------

echo "Test: chaining is preferred over paring"
# limit x max_comments is the budget, and a split body loses nothing where a
# pared one loses reviewer analysis. At this limit a single comment would need
# level 4; three comments hold the same findings whole.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Max comments: 3\n' >>"$sess/tracking.md"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '12000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
	printf '%s %s\n' "$RC_COMMENT_PARTS" "$RC_COMMENT_LEVEL" >"$sess/result"
	printf '%s\n' "${RC_COMMENT_PART_FILES[@]}" >"$sess/files"
)
read -r chain_parts chain_level <"$sess/result"
assert_equals "$chain_level" "0" "a chained body is not pared"
if [[ "$chain_parts" -gt 1 && "$chain_parts" -le 3 ]]; then
	echo "  PASS: split across $chain_parts parts, within the configured maximum"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected 2-3 parts, got $chain_parts"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the" "$sess"/comment-body*.md; then
	echo "  FAIL: a chained body claimed to be trimmed"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no disclosure line on a chained, unpared body"
	PASS=$((PASS + 1))
fi
# Every part must fit on its own: the budget is per comment, multiplied, not a
# single allowance the parts share unevenly.
chain_over=0
while IFS= read -r f; do
	part_len=$(body_bytes "$f")
	[[ "$part_len" -le 12000 ]] || chain_over=$((chain_over + 1))
done <"$sess/files"
assert_equals "$chain_over" "0" "every part fits the per-comment limit"
# Conservation: splitting must not lose a finding. Each fixture headline carries
# a unique "(case N)", so counting them across the parts counts the findings.
# Summed file by file rather than with `grep -hc`, which is not POSIX.
chain_findings=0
while IFS= read -r f; do
	chain_findings=$((chain_findings + $(grep -cF "(case " "$f" || true)))
done <"$sess/files"
assert_equals "$chain_findings" "30" "no finding is lost in the split"
rm -rf "$sess"

echo "Test: each part is identified and self-describing"
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Max comments: 3\n' >>"$sess/tracking.md"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '12000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
# The marker is how the poster matches a re-render against the comments it wrote
# last time. Without part/of it can only find "some council comment for this
# sha" and would update the wrong one.
for part in 1 2 3; do
	if [[ "$part" -eq 1 ]]; then part_file="$sess/comment-body.md"; else part_file="$sess/comment-body.part${part}.md"; fi
	if grep -qF "review-council:marker sha=" "$part_file" &&
		grep -qF "part=${part} of=3" "$part_file"; then
		echo "  PASS: part ${part} is marked part=${part} of=3"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: part ${part} does not identify its place in the chain"
		FAIL=$((FAIL + 1))
	fi
done
# Only the head carries the verdict and the substitution point for part links; a
# reader landing on a tail is told where the summary is.
if grep -qF "Review Council: REQUEST CHANGES" "$sess/comment-body.md" &&
	! grep -qF "Review Council: REQUEST CHANGES" "$sess/comment-body.part2.md"; then
	echo "  PASS: the verdict heading appears once, on the head"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the verdict heading is missing or repeated across parts"
	FAIL=$((FAIL + 1))
fi
if grep -qF "review-council:part-links" "$sess/comment-body.md" &&
	! grep -qF "review-council:part-links" "$sess/comment-body.part2.md"; then
	echo "  PASS: the part-link substitution point is on the head only"
	PASS=$((PASS + 1))
else
	echo "  FAIL: part-link token misplaced"
	FAIL=$((FAIL + 1))
fi
if grep -qF "The verdict and summary are in part 1." "$sess/comment-body.part2.md"; then
	echo "  PASS: a tail part points back at the head"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a tail part does not say where the verdict is"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: a re-render that needs fewer parts removes the stale ones"
# A run that needed three comments followed by one that needs two must not leave
# the third on disk: the poster reads the part files, and an orphan would be
# posted as a part of a chain it no longer belongs to.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Max comments: 3\n' >>"$sess/tracking.md"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '12000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
if [[ -e "$sess/comment-body.part3.md" ]]; then
	echo "  PASS: three parts on the first render"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the first render did not produce three parts"
	FAIL=$((FAIL + 1))
fi
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '1000000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
)
if [[ ! -e "$sess/comment-body.part2.md" && ! -e "$sess/comment-body.part3.md" ]]; then
	echo "  PASS: stale parts removed when the chain shortens"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a stale part file survived the re-render"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test: chaining and paring compose when even the budget is exceeded"
# Three comments of 3,000 is 9,000 against a 27,896-char body. Chaining alone
# cannot save this; the ladder runs against the multiplied budget.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
printf -- '- Max comments: 3\n' >>"$sess/tracking.md"
(
	# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
	source "$SCRIPT"
	rc_comment_limit() { printf '3000'; }
	rc_render_comment_body "$sess" "$sess/comment-body.md"
	printf '%s %s\n' "$RC_COMMENT_PARTS" "$RC_COMMENT_LEVEL" >"$sess/result"
)
read -r both_parts both_level <"$sess/result"
if [[ "$both_level" -gt 0 && "$both_parts" -gt 1 ]]; then
	echo "  PASS: pared to level $both_level AND split across $both_parts parts"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected both mechanisms (level=$both_level parts=$both_parts)"
	FAIL=$((FAIL + 1))
fi
both_over=0
for f in "$sess"/comment-body.md "$sess"/comment-body.part*.md; do
	[[ -e "$f" ]] || continue
	part_len=$(body_bytes "$f")
	[[ "$part_len" -le 3000 ]] || both_over=$((both_over + 1))
done
assert_equals "$both_over" "0" "every part still fits the per-comment limit"
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  PASS: the head discloses the trim"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a pared chain does not disclose"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# --- Deselected reviewers are disclosed on the PR (issue #20) ----------------
#
# The reviewer table is built from arriving verdicts, so a persona the council
# never dispatched is simply not in it — and a short table reads as a full
# council. The PR comment is the artifact a maintainer actually sees, so it is
# the one that most needs to tell "found nothing" from "was not asked".
echo "Test: a deselected reviewer gets its own row with the reason"
sess=$(mktemp -d)
make_review_session "$sess"
cat >"$sess/session-manifest.json" <<'MJ'
{"mode":"code","suffix":"code",
 "agents":["divisor-adversary-code","divisor-sre-code","divisor-testing-code"],
 "absent":[],
 "council":["divisor-adversary-code"],
 "deselected":[{"agent":"divisor-sre-code","persona":"sre",
                "reason":"docs-only changeset: no runtime, deployment or permission surface"},
               {"agent":"divisor-testing-code","persona":"testing",
                "reason":"docs-only changeset: no code or test surface to review"}],
 "selection":{"applied":true,"shape":"docs-only","reason":"prose only","pinned":[]}}
MJ
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "renders with a narrowed council"
body=$(cat "$sess/comment-body.md")
for needle in "⏭️ Skipped: docs-only changeset: no runtime" "⏭️ Skipped: docs-only changeset: no code or test surface"; do
	if grep -qF "$needle" <<<"$body"; then
		echo "  PASS: discloses '$needle'"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: missing '$needle'"
		FAIL=$((FAIL + 1))
	fi
done
# The house rule the whole body obeys: no em or en dashes. A skipped row is
# assembled after the dash pass has run, so it has to be clean on its own.
if [[ "$body" != *—* && "$body" != *–* ]]; then
	echo "  PASS: skipped rows carry no em/en dash"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a skipped row introduced an em/en dash"
	FAIL=$((FAIL + 1))
fi
# Three columns per row, so the skipped rows do not break the table.
bad_rows=$(grep -c '^| .* | ⏭️ Skipped: [^|]* | - |$' <<<"$body" || true)
assert_equals "$bad_rows" "2" "both skipped rows are well-formed three-column rows"
rm -rf "$sess"

echo "Test: a session with no deselections renders no skipped row"
sess=$(mktemp -d)
make_review_session "$sess"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "Skipped:" "$sess/comment-body.md"; then
	echo "  FAIL: a full-council run claims a skip"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: a full-council run claims no skip"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
