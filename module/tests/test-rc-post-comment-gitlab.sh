#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-gitlab.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# rc-post-comment-gitlab.sh renders and never posts. That makes the negative
# cases the interesting ones: the script has to refuse cleanly on every input
# shape the router can hand it, and - the property it exists for - it must NEVER
# write upstream, including when the caller passes --send.
#
# There is no `glab` mock here on purpose. The script makes no forge calls at
# all, so a mock would test nothing; what is asserted instead is that no forge
# binary is ever needed, which a mock would hide.

# GitLab origin, so the renderer derives a gitlab.example.com forge web root.
GL_ORIGIN="https://gitlab.example.com/acme/widgets.git"

echo "Test 0: the declared limit is GitLab's actual note cap"
# The number that makes the hook worth having: fifteen times GitHub's, so the
# same review that has to be pared there posts whole here. Collapsing it toward
# GitHub's value would silently trim GitLab bodies that never needed trimming.
gl_limit=$(sed -n '/^rc_comment_limit()/,/^}/p' "$SCRIPT" | sed -nE "s/.*printf '([0-9]+)'.*/\1/p")
assert_equals "$gl_limit" "1000000" "GitLab's note limit is declared as 1000000"

echo "Test 1: renders a body and reports it for manual posting"
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered"
assert_json_field "$result" "parts" "1" "one part"
assert_json_field "$result" "pare_level" "0" "nothing pared"
if echo "$result" | jq -r '.message' | grep -qF "post it manually"; then
	echo "  PASS: the message says posting is not implemented"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the message does not tell the caller to post manually"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | jq -r '.message' | grep -qF "!7"; then
	echo "  PASS: the merge request is named with GitLab's own sigil"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the merge request number is missing or wrongly sigiled"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 2: permalinks use GitLab's /-/ separator, not GitHub's route"
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
bash "$SCRIPT" "$sess" >/dev/null 2>&1
body="$sess/comment-body.md"
if grep -qF "https://gitlab.example.com/acme/widgets/-/blob/" "$body"; then
	echo "  PASS: file deep-link built with /-/blob/"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no GitLab file deep-link"
	FAIL=$((FAIL + 1))
fi
if grep -qF "https://gitlab.example.com/acme/widgets/-/commit/" "$body"; then
	echo "  PASS: commit stamp built with /-/commit/"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no GitLab commit link"
	FAIL=$((FAIL + 1))
fi
# A GitHub-shaped route here would still be a link, and still be wrong.
if grep -qE 'gitlab\.example\.com/acme/widgets/(blob|commit)/' "$body"; then
	echo "  FAIL: a GitHub-shaped route leaked into a GitLab body"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no GitHub-shaped routes"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo "Test 3: an unparseable origin degrades to plain spans, never to gitlab.com"
# Self-hosted is the common case on GitLab, so guessing a public host would
# produce links that are confidently wrong rather than absent.
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 ""
bash "$SCRIPT" "$sess" >/dev/null 2>&1
if grep -qF "gitlab.com" "$sess/comment-body.md"; then
	echo "  FAIL: defaulted to gitlab.com with no usable origin"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no guessed host"
	PASS=$((PASS + 1))
fi
# shellcheck disable=SC2016 # a literal markdown code span in the expected output
if grep -qF '`auth/token.go:1`' "$sess/comment-body.md"; then
	echo "  PASS: the finding degraded to a plain code span"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the finding location is neither linked nor a plain span"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 4: GitLab's own limit is what applies, not GitHub's"
# The whole reason the limit is a per-forge hook. A 30-finding body is 27k:
# over nothing on GitLab, and it must come out whole.
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
make_review_session_many "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "pare_level" "0" "a 30-finding body is unpared on GitLab"
assert_equals "$(grep -cF "💬 Full reviewer analysis" "$sess/comment-body.md" || true)" "30" \
	"every finding keeps its analysis"
if grep -qF "Trimmed to fit the" "$sess/comment-body.md"; then
	echo "  FAIL: GitLab pared a body that fits its note limit"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: no disclosure line"
	PASS=$((PASS + 1))
fi
rm -rf "$sess"

echo "Test 5: a recorded Comment limit overrides the forge, and is disclosed"
# Self-hosted GitLab behind a proxy that truncates bodies is exactly the case
# the override exists for.
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
make_review_session_many "$sess"
printf -- '- Comment limit: 20000\n' >>"$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
gl_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
if [[ "$gl_bytes" -le 20000 ]]; then
	echo "  PASS: the override was honoured ($gl_bytes <= 20000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the forge limit won over the recorded one ($gl_bytes)"
	FAIL=$((FAIL + 1))
fi
if grep -qF "Trimmed to fit the gitlab comment limit" "$sess/comment-body.md"; then
	echo "  PASS: the disclosure names the forge"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a pared GitLab body did not disclose"
	FAIL=$((FAIL + 1))
fi
if echo "$result" | jq -r '.message' | grep -qF "Trimmed to fit the note limit"; then
	echo "  PASS: the status envelope reports the trim too"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the trim is only in the body a human may never open"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 6: --send is accepted and still posts nothing"
# The router passes the caller's flags through verbatim. Rejecting --send would
# report "you used the wrong flag" for what is really "GitLab cannot post yet",
# and honouring it would write upstream through a policy that does not exist.
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
bin=$(mktemp -d)
# Any forge call at all is a failure, so make both CLIs fatal if invoked.
for cli in glab gh; do
	# shellcheck disable=SC2016 # $* and $FORGE_LOG are for the stub to expand
	# when it runs, not for this suite to expand while writing it.
	printf '#!/usr/bin/env bash\necho "FORGE CALL: %s $*" >>"$FORGE_LOG"\nexit 1\n' "$cli" >"$bin/$cli"
	chmod +x "$bin/$cli"
done
: >"$bin/forge.log"
result=$(PATH="$bin:$PATH" FORGE_LOG="$bin/forge.log" REVIEW_COUNCIL_ALLOW_POST=1 \
	bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "rendered" "--send still only renders"
if [[ ! -s "$bin/forge.log" ]]; then
	echo "  PASS: no forge call was made, even with --send and ALLOW_POST=1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the script reached the forge:"
	sed 's/^/        /' "$bin/forge.log"
	FAIL=$((FAIL + 1))
fi
# `posted` is the status that tells the orchestrator to report a comment landed.
gl_status=$(jq -r '.status' <<<"$result")
if [[ "$gl_status" != "posted" ]]; then
	echo "  PASS: never reports 'posted'"
	PASS=$((PASS + 1))
else
	echo "  FAIL: claimed to post a comment it did not post"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 7: refuses cleanly on every malformed invocation"
# Each of these is a `skip`, not an error: nothing was wrong, there was simply
# nothing to do. A crash here would surface as a broken pipeline stage rather
# than as the no-op it is.
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
result=$(bash "$SCRIPT" "$sess" --bogus 2>/dev/null)
assert_json_field "$result" "status" "skip" "an unknown flag is a skip"
if echo "$result" | jq -r '.message' | grep -qF -- "--bogus"; then
	echo "  PASS: the offending flag is named"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the message does not say which flag"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

result=$(bash "$SCRIPT" "/nonexistent/session/$$" 2>/dev/null)
assert_json_field "$result" "status" "skip" "a missing session directory is a skip"
result=$(bash "$SCRIPT" 2>/dev/null)
assert_json_field "$result" "status" "skip" "no arguments at all is a skip"

sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
rm -f "$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "skip" "a session with no tracking.md is a skip"
rm -rf "$sess"

sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
printf '# Review Council Session Tracking\n\n- Forge: gitlab\n- PR: none\n' >"$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "skip" "no merge request is a skip"
if [[ ! -f "$sess/comment-body.md" ]]; then
	echo "  PASS: nothing rendered when there is nowhere to post it"
	PASS=$((PASS + 1))
else
	echo "  FAIL: rendered a body for a session with no merge request"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo "Test 8: an oversized verdict chains here too"
sess=$(mktemp -d)
make_review_session "$sess" gitlab 7 "$GL_ORIGIN"
make_review_session_many "$sess"
printf -- '- Comment limit: 12000\n- Max comments: 3\n' >>"$sess/tracking.md"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "parts" "3" "split across three notes"
assert_json_field "$result" "pare_level" "0" "chained rather than pared"
part_files=$(echo "$result" | jq -r '.part_files | length')
assert_equals "$part_files" "3" "every part is reported for manual posting"
if echo "$result" | jq -r '.message' | grep -qF "in 3 parts"; then
	echo "  PASS: the message says there is more than one note to paste"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a chained render read as a single body"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
