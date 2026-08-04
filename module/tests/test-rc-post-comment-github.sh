#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-github.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Mock gh: logs args, and drives responses off env by inspecting the endpoint,
# method, --jq filter, and whether a -f body= arg was present. The github
# script's inline gh calls are:
#   find-by-sha : GET issues/<pr>/comments?per_page=100  --jq "... first // empty"
#   list-council: GET issues/<pr>/comments?per_page=100  --jq "... @tsv"
#   get-body    : GET issues/comments/<id>               --jq .body
#   create      : POST issues/<pr>/comments -f body=...  --jq .id
#   update      : PATCH issues/comments/<id> -X PATCH -f body=...
#   minimize    : graphql minimizeComment
# Env: MOCK_FIND (find-by-sha stdout), MOCK_FIND_RC (its exit), MOCK_GETBODY
# (file get-body cats), MOCK_NEWID (create stdout), MOCK_LIST (list-council %b),
# MOCK_ACTOR (`gh api user` login; set to "" to exercise the fail-closed path),
# MOCK_ACTOR_RC (its exit status — a real auth failure is non-zero plus stderr,
# not an empty success, and only that shape reaches the `|| echo ""` arm).
make_gh() {
	local dir="$1"
	mkdir -p "$dir"
	cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
args=("$@"); jqf=""; endpoint=""; method="GET"; is_graphql=0; hasbody=0
i=0
while [[ $i -lt ${#args[@]} ]]; do
	case "${args[$i]}" in
	graphql) is_graphql=1 ;;
	--jq) jqf="${args[$((i+1))]}"; i=$((i+1)) ;;
	-X) method="${args[$((i+1))]}"; i=$((i+1)) ;;
	-f) [[ "${args[$((i+1))]}" == body=* ]] && hasbody=1; i=$((i+1)) ;;
	api) : ;;
	-*) : ;;
	*) [[ -z "$endpoint" && $is_graphql -eq 0 ]] && endpoint="${args[$i]}" ;;
	esac
	i=$((i+1))
done
if [[ $is_graphql -eq 1 ]]; then echo '{"data":{"minimizeComment":{"minimizedComment":{"isMinimized":true}}}}'; exit 0; fi
case "$endpoint" in
user)
	if [[ "${MOCK_ACTOR_RC:-0}" -ne 0 ]]; then
		echo "gh: Requires authentication (HTTP 401)" >&2
		exit "$MOCK_ACTOR_RC"
	fi
	printf '%s' "${MOCK_ACTOR-council-bot}"
	exit 0
	;;
*/issues/comments/*)
	[[ "$method" == "PATCH" ]] && exit 0
	[[ -n "${MOCK_GETBODY:-}" ]] && cat "$MOCK_GETBODY"
	exit 0
	;;
*/comments*)
	if [[ $hasbody -eq 1 ]]; then printf '%s' "${MOCK_NEWID:-555}"; exit 0; fi
	if [[ "$jqf" == *"first // empty"* ]]; then printf '%s' "${MOCK_FIND:-}"; exit "${MOCK_FIND_RC:-0}"; fi
	if [[ "$jqf" == *"@tsv"* ]]; then printf '%b' "${MOCK_LIST:-}"; exit 0; fi
	exit 0
	;;
esac
exit 0
GH
	chmod +x "$dir/gh"
}

# Real-filter mock: runs the script's actual `gh api --jq` filters over a canned
# comments array (in $GH_COMMENTS) through REAL jq, so the marker+sha selection
# and the `capture("sha=...")` regex are genuinely exercised (guards the
# SHA-keyed upsert logic this refactor relocated). Create returns id 778.
# Comments in $GH_COMMENTS carry `.user.login`, so the author filter is real
# too; the authenticated login is $MOCK_ACTOR (default council-bot).
make_gh_realjq() {
	local dir="$1"
	mkdir -p "$dir"
	cat >"$dir/gh" <<'GH'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
args=("$@"); jqf=""; endpoint=""; method="GET"; is_graphql=0; hasbody=0
i=0
while [[ $i -lt ${#args[@]} ]]; do
	case "${args[$i]}" in
	graphql) is_graphql=1 ;;
	--jq) jqf="${args[$((i+1))]}"; i=$((i+1)) ;;
	-X) method="${args[$((i+1))]}"; i=$((i+1)) ;;
	-f) [[ "${args[$((i+1))]}" == body=* ]] && hasbody=1; i=$((i+1)) ;;
	api) : ;;
	-*) : ;;
	*) [[ -z "$endpoint" && $is_graphql -eq 0 ]] && endpoint="${args[$i]}" ;;
	esac
	i=$((i+1))
done
if [[ $is_graphql -eq 1 ]]; then echo '{"data":{}}'; exit 0; fi
case "$endpoint" in
user)
	printf '%s' "${MOCK_ACTOR-council-bot}"
	exit 0
	;;
esac
comments=$(cat "$GH_COMMENTS")
case "$endpoint" in
*/issues/comments/*)
	id="${endpoint##*/}"
	[[ "$method" == "PATCH" ]] && exit 0
	printf '%s' "$comments" | jq -r --argjson id "$id" '.[] | select(.id==$id) | .body'
	exit 0
	;;
*/comments*)
	[[ $hasbody -eq 1 ]] && { echo "778"; exit 0; }
	printf '%s' "$comments" | jq -r "$jqf"   # find-by-sha / list-council: REAL filter
	exit 0
	;;
esac
exit 0
GH
	chmod +x "$dir/gh"
}

# Test 1: dry-run (no --send) renders body, does not post
echo "Test 1: dry-run render"
sess=$(mktemp -d)
make_review_session "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered (dry-run)"
if grep -qF "<!-- review-council:marker sha=" "$sess/comment-body.md"; then
	echo "  PASS: body rendered"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no body"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 2: --send, no existing comment -> create, superseded 0
echo "Test 2: send creates a new comment"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="777" MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "posted" "status is posted"
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded')
if [[ "$sup" -eq 0 ]]; then
	echo "  PASS: superseded=0"
	PASS=$((PASS + 1))
else
	echo "  FAIL: superseded=$sup"
	FAIL=$((FAIL + 1))
fi
if grep -q 'issues/42/comments' "$bin/log" && grep -q -- '-f body=' "$bin/log"; then
	echo "  PASS: create POST issued"
	PASS=$((PASS + 1))
else
	echo "  FAIL: create not issued"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 3: --send, existing comment for this SHA, identical body -> unchanged
echo "Test 3: send no-op when body unchanged"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # pre-render deterministic body
cp "$sess/comment-body.md" "$bin/prior.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="900" MOCK_GETBODY="$bin/prior.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "unchanged" "action is unchanged"
if ! grep -q -- '-X PATCH' "$bin/log"; then
	echo "  PASS: no PATCH for identical body"
	PASS=$((PASS + 1))
else
	echo "  FAIL: PATCH issued"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 4: --send, existing comment for this SHA, different body -> update
echo "Test 4: send updates in place when body differs"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "stale prior body" >"$bin/stale.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="901" MOCK_GETBODY="$bin/stale.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "updated" "action is updated"
if grep -q 'issues/comments/901' "$bin/log" && grep -q -- '-X PATCH' "$bin/log"; then
	echo "  PASS: PATCH 901"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no PATCH 901"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 5: new commit + a prior comment on another SHA -> create + supersede
echo "Test 5: new commit supersedes prior comment"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "an older council comment" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="778" \
	MOCK_LIST="808\tNODE808\tdeadbeefdeadbeef\n" MOCK_GETBODY="$bin/old.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded')
if [[ "$sup" -eq 1 ]]; then
	echo "  PASS: superseded=1"
	PASS=$((PASS + 1))
else
	echo "  FAIL: superseded=$sup"
	FAIL=$((FAIL + 1))
fi
if grep -q 'issues/comments/808' "$bin/log" && grep -q -- '-X PATCH' "$bin/log" && grep -q 'NODE808' "$bin/log"; then
	echo "  PASS: prior comment updated + minimized"
	PASS=$((PASS + 1))
else
	echo "  FAIL: supersede did not update+minimize"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 6: find-by-sha lookup FAILS -> status error, nothing posted
echo "Test 6: lookup failure reports error"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND_RC=1 \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error on lookup failure"
rm -rf "$sess" "$bin"

# Test 7: gh absent -> render-only degrade even with --send
echo "Test 7: gh absent degrades to render-only"
sess=$(mktemp -d)
make_review_session "$sess"
gbin=$(mktemp -d)
nogh=$(path_without_command gh "$gbin")
# The degrade is only under test if gh really is unreachable while the
# interpreter still is. Exit 1 is the wanted "no such command"; 0 means the
# mask missed gh and 127 means it took bash with it, which is the failure the
# system-bindir mirror this replaced produced on macOS.
rc=0
PATH="$nogh" bash -c 'command -v gh' >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 1 ]]; then
	echo "  PASS: gh masked from PATH, interpreter intact"
	PASS=$((PASS + 1))
else
	echo "  FAIL: masked PATH unusable (rc=$rc; 0=gh still found, 127=no bash)"
	FAIL=$((FAIL + 1))
fi
result=$(PATH="$nogh" bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "rendered" "degrades to rendered when gh missing"
rm -rf "$sess" "$gbin"

# Test 8: --send WITHOUT REVIEW_COUNCIL_ALLOW_POST refuses to post (hard gate)
echo "Test 8: refuses to post without REVIEW_COUNCIL_ALLOW_POST"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" \
	bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "confirm_required" "status is confirm_required without allow-post"
if [[ ! -s "$bin/log" ]]; then
	echo "  PASS: gh never invoked"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh invoked despite gate"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 9: REAL find-by-sha filter selects the comment whose marker carries this
# commit's SHA (body identical) -> unchanged. Exercises the actual
# contains(marker) and contains(sha=...) selection + get-body over real jq.
echo "Test 9: real find-by-sha filter matches this SHA (unchanged)"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render the deterministic body (marker carries head sha)
rbody=$(cat "$sess/comment-body.md")
jq -n --arg b "$rbody" '[{id:900, node_id:"NODE900", user:{login:"council-bot"}, body:$b}]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "unchanged" "real filter finds the sha-matched comment"
rm -rf "$sess" "$bin"

# Test 10: REAL list-council filter supersedes ONLY marker comments on other
# SHAs, excluding a non-council comment. Exercises the capture("sha=...") regex
# and the marker filter, plus find-by-sha returning empty for an absent SHA.
echo "Test 10: real list-council filter supersedes council only, excludes non-council"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
jq -n '[
  {id:808, node_id:"NODE808", user:{login:"council-bot"}, body:"old council <!-- review-council:marker sha=deadbeefdeadbeef -->"},
  {id:700, node_id:"NODE700", user:{login:"human"}, body:"unrelated human comment"}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "no sha match -> created"
sup=$(echo "$result" | jq '.superseded')
if [[ "$sup" -eq 1 ]]; then
	echo "  PASS: superseded=1 (council only)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: superseded=$sup"
	FAIL=$((FAIL + 1))
fi
# Match comment 700 the same precise way 808 is matched. A bare `grep -q '700'`
# scans the whole log, which also carries the session timestamp and generated
# comment ids — any of which can contain those three digits (a run at 07:00,
# for instance). That made this assertion fail at random, pointing at the
# poster instead of at the test.
if grep -q 'issues/comments/808' "$bin/log" && grep -q 'NODE808' "$bin/log" &&
	! grep -q 'issues/comments/700' "$bin/log" && ! grep -q 'NODE700' "$bin/log"; then
	echo "  PASS: council 808 superseded, non-council 700 untouched"
	PASS=$((PASS + 1))
else
	echo "  FAIL: supersede touched the wrong comments"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 11: missing origin - the forge-neutral renderer leaves RC_FORGE_WEB
# empty (see test-rc-render-comment.sh Test 8), but this poster is
# definitionally GitHub, so it still deep-links via its own github.com
# default. Confirms the relocation actually preserves GitHub UX on the edge
# case, not just the parseable-origin normal case already covered above.
echo "Test 11: missing origin still deep-links via GitHub poster default"
sess=$(mktemp -d)
make_review_session "$sess" github 42 ""
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered (dry-run, missing origin)"
body=$(cat "$sess/comment-body.md")
if grep -qF "https://github.com/acme/widgets/blob/" <<<"$body" && grep -qF "#L1" <<<"$body"; then
	echo "  PASS: GitHub poster defaults host to github.com for missing origin"
	PASS=$((PASS + 1))
else
	echo "  FAIL: GitHub poster did not default host for missing origin"
	FAIL=$((FAIL + 1))
fi
if grep -qF "https://github.com/acme/widgets/commit/" <<<"$body"; then
	echo "  PASS: commit stamp also defaults to github.com"
	PASS=$((PASS + 1))
else
	echo "  FAIL: commit stamp did not default to github.com"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess"

# Test 12: the marker is a public string — it ships in every verdict comment and
# verbatim in the docs — so it cannot be the sole proof that a comment is ours.
# A PR participant who pastes it (with this commit's sha) would otherwise have
# their comment body overwritten by the verdict, or banner-stamped and hidden.
# Council identity is marker AND author, so only the posting account's comment
# may be selected.
echo "Test 12: comment selection requires the posting account as author"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render to learn this run's head sha
head_sha=$(sed -n 's/.*review-council:marker sha=\([0-9a-fA-F]*\).*/\1/p' "$sess/comment-body.md")
jq -n --arg sha "$head_sha" '[
  {id:808, node_id:"NODE808", user:{login:"council-bot"}, body:"old council <!-- review-council:marker sha=deadbeefdeadbeef -->"},
  {id:701, node_id:"NODE701", user:{login:"mallory"}, body:"forged <!-- review-council:marker sha=\($sha) -->"},
  {id:702, node_id:"NODE702", user:{login:"mallory"}, body:"forged older <!-- review-council:marker sha=feedfacefeedface -->"}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" MOCK_ACTOR="council-bot" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "forged sha match is not treated as our comment"
sup=$(echo "$result" | jq '.superseded')
if [[ "$sup" -eq 1 ]]; then
	echo "  PASS: superseded=1 (own comment only)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: superseded=$sup (expected 1; forged comments were counted)"
	FAIL=$((FAIL + 1))
fi
if grep -q 'issues/comments/808' "$bin/log" &&
	! grep -q 'issues/comments/701' "$bin/log" && ! grep -q 'NODE701' "$bin/log" &&
	! grep -q 'issues/comments/702' "$bin/log" && ! grep -q 'NODE702' "$bin/log"; then
	echo "  PASS: third-party marker comments never read, edited or hidden"
	PASS=$((PASS + 1))
else
	echo "  FAIL: third-party marker comments were touched"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 13: with no resolvable actor there is no author to filter on, and the
# only remaining selector is the public marker. Fail closed rather than fall
# back to it — an empty `.user.login` comparison matches nothing or everything
# depending on the filter, and neither is safe to guess at.
echo "Test 13: unresolvable actor fails closed"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_ACTOR="" MOCK_FIND="" MOCK_NEWID="779" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error when the actor is unresolvable"
if ! grep -q -- '-f body=' "$bin/log" && ! grep -q -- '-X PATCH' "$bin/log"; then
	echo "  PASS: nothing created or updated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: wrote to the PR without knowing the acting account"
	FAIL=$((FAIL + 1))
fi
# A real auth failure is not an empty success — `gh api user` exits non-zero and
# explains itself on stderr. That is the shape the `|| echo ""` arm exists for,
# so drive it directly rather than only through an empty stdout.
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log2" MOCK_ACTOR_RC=1 MOCK_FIND="" MOCK_NEWID="779" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error when gh api user exits non-zero"
msg=$(echo "$result" | jq -r '.message')
if grep -q 'gh auth status' <<<"$msg"; then
	echo "  PASS: message points at gh auth status"
	PASS=$((PASS + 1))
else
	echo "  FAIL: message gives the user nothing to act on"
	FAIL=$((FAIL + 1))
fi
# The login is interpolated into a jq string literal, so a value carrying a
# quote would close it and let the rest be read as filter syntax. Only a
# login-shaped value is accepted; anything else takes the same closed door —
# but with its own message, since the account WAS resolved, just not usable.
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log3" MOCK_ACTOR='x" or true or "' MOCK_FIND="" MOCK_NEWID="779" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error when the login is not login-shaped"
msg=$(echo "$result" | jq -r '.message')
if grep -q 'not login-shaped' <<<"$msg"; then
	echo "  PASS: shape failure reported as its own cause, not as unresolvable"
	PASS=$((PASS + 1))
else
	echo "  FAIL: shape failure misreported"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
