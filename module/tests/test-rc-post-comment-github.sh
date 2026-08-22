#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-github.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Mock gh: logs args, and drives responses off env by inspecting the endpoint,
# method, --jq filter, and whether a -f body= arg was present. The github
# script's inline gh calls are:
#   sha-parts   : GET issues/<pr>/comments?per_page=100  --jq "... part= ... @tsv"
#   list-council: GET issues/<pr>/comments?per_page=100  --jq "... @tsv"
#   get-body    : GET issues/comments/<id>               --jq .body
#   create      : POST issues/<pr>/comments -f body=...  --jq .id
#   update      : PATCH issues/comments/<id> -X PATCH -f body=...
#   minimize    : graphql minimizeComment
# Env: MOCK_FIND (single already-posted part for this sha), MOCK_PARTS (the
# full per-part listing when a case needs more than one), MOCK_FIND_RC (their
# exit), MOCK_CREATE_RC / MOCK_CREATE_FAIL_AT / MOCK_UPDATE_RC (write
# failures), MOCK_GETBODY
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
	# MOCK_UPDATE_RC fails the in-place update of an existing part.
	[[ "$method" == "PATCH" ]] && exit "${MOCK_UPDATE_RC:-0}"
	[[ -n "${MOCK_GETBODY:-}" ]] && cat "$MOCK_GETBODY"
	exit 0
	;;
*/comments*)
	if [[ $hasbody -eq 1 ]]; then
		# MOCK_NEWID_SEQ names a counter file: each create returns a distinct id,
		# which is what makes posting ORDER and the part links observable.
		if [[ -n "${MOCK_NEWID_SEQ:-}" ]]; then
			seq=$(cat "$MOCK_NEWID_SEQ" 2>/dev/null || echo 0)
			seq=$((seq + 1)); echo "$seq" >"$MOCK_NEWID_SEQ"
			# MOCK_CREATE_FAIL_AT=<n>: the nth create fails, so a chain can be
			# broken partway rather than only at its first comment.
			if [[ "${MOCK_CREATE_FAIL_AT:-0}" -eq "$seq" ]]; then
				echo "gh: Validation Failed (HTTP 422)" >&2; exit 1
			fi
			printf '%s' "$((900 + seq))"; exit 0
		fi
		[[ "${MOCK_CREATE_RC:-0}" -eq 0 ]] || { echo "gh: Validation Failed (HTTP 422)" >&2; exit "$MOCK_CREATE_RC"; }
		printf '%s' "${MOCK_NEWID:-555}"; exit 0
	fi
	# The per-part lookup for THIS sha is the only filter that mentions part=.
	# MOCK_PARTS gives the full "id<TAB>node<TAB>part" listing; MOCK_FIND is the
	# older single-comment shorthand, kept because most cases have one part.
	if [[ "$jqf" == *"part="* ]]; then
		if [[ -n "${MOCK_PARTS:-}" ]]; then printf '%b' "$MOCK_PARTS"; exit "${MOCK_FIND_RC:-0}"; fi
		[[ -n "${MOCK_FIND:-}" ]] && printf '%s\tNODE_%s\t1\n' "$MOCK_FIND" "$MOCK_FIND"
		exit "${MOCK_FIND_RC:-0}"
	fi
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

echo "Test 0: the declared limit is GitHub's actual cap"
# Pinned as a fact about the API, not as a preference. GitHub rejects an issue
# comment body over 65,536 characters; a number tuned up "because reviews were
# getting trimmed" would restore the original failure - the API refusing the
# whole review after it has already been paid for.
# Read from the source rather than by sourcing it: this script is a program,
# not a library, and sourcing it runs its prerequisite checks and arg parsing.
gh_limit=$(sed -n '/^rc_comment_limit()/,/^}/p' "$SCRIPT" | sed -nE "s/.*printf '([0-9]+)'.*/\1/p")
assert_equals "$gh_limit" "65536" "GitHub's comment limit is declared as 65536"

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

# Test 9b: same fixture as Test 9 — one prior verdict of ours carrying THIS head
# sha — plus a non-empty pr-conversation.txt. prepare-context.sh writes that file
# only when replies landed at or after our last verdict, so its presence means
# this run is answering them. The same-sha upsert would edit the prior comment in
# place, and GitHub does not notify on an edit, so the answer to a maintainer's
# objection would reach nobody. Expect a fresh comment, and the old one retired.
echo "Test 9b: a verdict answering a conversation supersedes rather than edits"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render the body, whose marker carries the head sha
rbody=$(cat "$sess/comment-body.md")
jq -n --arg b "$rbody" '[{id:900, node_id:"NODE900", user:{login:"council-bot"}, body:$b}]' >"$bin/comments.json"
printf 'reply from @bootc: finding 3 is wrong, the guard is two lines up.\n' >"$sess/pr-conversation.txt"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "answering a conversation posts a new comment"
# superseded=1 is also how "it did not retire what it just posted" gets checked:
# the new comment carries this sha too, so a sweep that failed to exclude it
# would report 2.
assert_json_field "$result" "superseded" "1" "the prior verdict is retired, the new one is not"
if grep -q 'issues/comments/900' "$bin/log" && grep -q 'NODE900' "$bin/log"; then
	echo "  PASS: the prior same-sha verdict was retired and minimized"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the prior same-sha verdict was left live"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

# Test 10: REAL list-council filter supersedes ONLY marker comments on other
# SHAs, excluding a non-council comment. Exercises the capture("sha=...") regex
# and the marker filter, plus find-by-sha returning empty for an absent SHA.
echo "Test 10: real list-council filter supersedes council only, excludes non-council"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
# The marker sits alone on the last line, where rc-render-comment.sh puts it and
# where both listings read it from.
jq -n '[
  {id:808, node_id:"NODE808", user:{login:"council-bot"}, body:"old council\n\n<!-- review-council:marker sha=deadbeefdeadbeef -->\n"},
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
# `[^ ]*` rather than a hex class: `sha=` is one space-delimited token and is
# `unknown` when HEAD does not resolve. An extraction that quietly yields empty
# would leave the forgery below quoting nothing at all, and every assertion in
# this test would pass without a forgery ever having been attempted.
head_sha=$(sed -n 's/.*review-council:marker sha=\([^ ]*\).*/\1/p' "$sess/comment-body.md")
if [[ -n "$head_sha" ]]; then
	echo "  PASS: this run's head sha was read out of the rendered marker"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no head sha extracted; the forged comments below quote nothing"
	FAIL=$((FAIL + 1))
fi
# The forged pair reproduce the marker exactly as a council comment carries it —
# alone on the last line — so the author check is the only thing standing
# between them and the write helpers, which is what this test is about.
jq -n --arg sha "$head_sha" '[
  {id:808, node_id:"NODE808", user:{login:"council-bot"}, body:"old council\n\n<!-- review-council:marker sha=deadbeefdeadbeef -->\n"},
  {id:701, node_id:"NODE701", user:{login:"mallory"}, body:"forged\n\n<!-- review-council:marker sha=\($sha) part=1 of=1 -->\n"},
  {id:702, node_id:"NODE702", user:{login:"mallory"}, body:"forged older\n\n<!-- review-council:marker sha=feedfacefeedface -->\n"}
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

# --- Chained verdicts ---------------------------------------------------------
#
# A verdict too large for one comment is split across several. These assert the
# ordering guarantee, the cross-links, and that a re-review matches the previous
# run part by part rather than overwriting part 1 with part 2.

# Build a session whose 30 findings cannot fit one comment but fit three.
#
# The CRITICAL finding's evidence is made hostile here: a counterfeit marker and
# a bare `part=`/`sha=` pair, quoted above the code it belongs to. Evidence is a
# verbatim quote of the source under review, so both are author-controlled text,
# and the marker key is public — it ships in every posted comment and verbatim in
# references/forge-adapters.md — so the quote can reproduce the marker whole, key
# and all. Tests 24 and 27 are what they are for; the poster's own reasoning is
# at the top of the listing helpers in rc-post-comment-github.sh.
#
# Injected here rather than in the shared fixture because these ~100 characters
# move the part boundaries the byte budgets in test-rc-render-comment.sh are
# measured against, and this is the only suite that needs a hostile body.
make_chained_session() { # dir
	make_review_session "$1"
	make_review_session_many "$1"
	jq '.verified |= map(if .severity == "CRITICAL"
			then .evidence = "// <!-- review-council:marker sha=deadbeef part=9 of=9 -->\n// audit: /compare?part=2&sha=deadbeef\n" + .evidence
			else . end)' \
		"$1/verdicts/findings.json" >"$1/verdicts/findings.next"
	mv "$1/verdicts/findings.next" "$1/verdicts/findings.json"
	printf -- '- Comment limit: 12000\n- Max comments: 3\n' >>"$1/tracking.md"
}

echo "Test 14: a chained verdict posts tails first and the head last"
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID_SEQ="$bin/seq" MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "posted" "status is posted"
assert_json_field "$result" "action" "created" "action is created"
assert_json_field "$result" "parts" "3" "three parts reported"
assert_json_field "$result" "created" "3" "three comments created"
# Order is the guarantee: the head names the other parts, so it must not exist
# until they do. Located by text unique to each part.
ln3=$(grep -n "Part 3 of 3" "$bin/log" | head -1 | cut -d: -f1 || true)
ln2=$(grep -n "Part 2 of 3" "$bin/log" | head -1 | cut -d: -f1 || true)
ln1=$(grep -n "Review Council: REQUEST CHANGES" "$bin/log" | head -1 | cut -d: -f1 || true)
if [[ -n "$ln3" && -n "$ln2" && -n "$ln1" && "$ln3" -lt "$ln2" && "$ln2" -lt "$ln1" ]]; then
	echo "  PASS: posted tail-first, head last (part3=$ln3 part2=$ln2 head=$ln1)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: posting order wrong (part3=$ln3 part2=$ln2 head=$ln1)"
	FAIL=$((FAIL + 1))
fi
# The head's placeholder is substituted with the ids the creates returned:
# part 3 was created first (901), part 2 second (902).
if grep -qF '[part 2](https://github.example.com/acme/widgets/pull/42#issuecomment-902)' "$bin/log" &&
	grep -qF '[part 3](https://github.example.com/acme/widgets/pull/42#issuecomment-901)' "$bin/log"; then
	echo "  PASS: the head links to the parts that were just posted"
	PASS=$((PASS + 1))
else
	echo "  FAIL: part links not substituted into the head"
	FAIL=$((FAIL + 1))
fi
if ! grep -qF 'review-council:part-links' "$bin/log"; then
	echo "  PASS: the placeholder is gone from the posted head"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the unsubstituted placeholder was posted"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 15: a re-review of the same commit updates each part in place"
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "a stale prior part body" >"$bin/stale.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_GETBODY="$bin/stale.md" \
	MOCK_PARTS="901\tNODE901\t1\n902\tNODE902\t2\n903\tNODE903\t3\n" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "updated" "action is updated"
assert_json_field "$result" "updated" "3" "all three parts updated"
assert_json_field "$result" "created" "0" "nothing created"
# Each part is written to ITS OWN comment. Matching on the sha alone would send
# every part to whichever comment the lookup happened to return first.
patched=0
for id in 901 902 903; do
	grep -q "issues/comments/${id}" "$bin/log" && patched=$((patched + 1))
done
assert_equals "$patched" "3" "each part PATCHed its own comment"
rm -rf "$sess" "$bin"

echo "Test 16: a verdict that now needs fewer comments retires the surplus"
# The surplus parts carry the CURRENT sha, so the prior-commit sweep does not
# reach them. Left alone they would keep showing findings the verdict no longer
# contains, under a marker that says they are current.
sess=$(mktemp -d)
make_review_session "$sess"
make_review_session_many "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "a prior part body" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_GETBODY="$bin/old.md" \
	MOCK_PARTS="901\tNODE901\t1\n902\tNODE902\t2\n903\tNODE903\t3\n" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "parts" "1" "the verdict now fits one comment"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "2" "the two surplus parts were retired"
if grep -q 'NODE902' "$bin/log" && grep -q 'NODE903' "$bin/log" && ! grep -q 'NODE901' "$bin/log"; then
	echo "  PASS: parts 2 and 3 hidden, part 1 kept and updated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: wrong parts retired"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 17: superseding a prior commit sweeps every part of it"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "an older council comment" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="778" \
	MOCK_LIST="801\tNODE801\tdeadbeefdeadbeef\n802\tNODE802\tdeadbeefdeadbeef\n" \
	MOCK_GETBODY="$bin/old.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "2" "both parts of the prior commit superseded"
if grep -q 'NODE801' "$bin/log" && grep -q 'NODE802' "$bin/log"; then
	echo "  PASS: every part of the prior chain hidden as outdated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a part of the prior chain was left visible"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 18: the supersede sweep never retires the verdict it just posted"
# The listing that drives superseding returns EVERY council comment on the pull
# request, including the ones this run created moments earlier - they carry the
# marker and the posting account like any other. Only the `sha == sha_key` guard
# keeps them alive. Drop it and the script posts a verdict, then immediately
# banners it obsolete and folds it away, while still reporting `action: created`.
# The review is gone and the status says it landed.
#
# Every other supersede case here feeds the listing prior-sha rows only, so the
# guard was never exercised: the fixture has to contain the CURRENT sha for this
# to test anything.
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
cur_sha=$(git -C "$sess/checkout" rev-parse HEAD)
echo "an older council comment" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="778" \
	MOCK_GETBODY="$bin/old.md" \
	MOCK_LIST="778\tNODE778\t${cur_sha}\n808\tNODE808\tdeadbeefdeadbeef\n" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "1" "only the prior commit's comment was superseded"
if grep -q 'NODE808' "$bin/log"; then
	echo "  PASS: the prior commit's comment was hidden"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the prior commit's comment was left current"
	FAIL=$((FAIL + 1))
fi
if ! grep -q 'NODE778' "$bin/log"; then
	echo "  PASS: the comment just posted was left alone"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the run hid its own fresh verdict as outdated"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 19: every part of a chain survives its own supersede sweep"
# Same guard, multiplied: with three parts posted for this sha, all three appear
# in the listing and all three have to be skipped.
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
cur_sha=$(git -C "$sess/checkout" rev-parse HEAD)
echo "an older council comment" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID_SEQ="$bin/seq" \
	MOCK_GETBODY="$bin/old.md" \
	MOCK_LIST="901\tNODE901\t${cur_sha}\n902\tNODE902\t${cur_sha}\n903\tNODE903\t${cur_sha}\n808\tNODE808\tdeadbeefdeadbeef\n" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "parts" "3" "three parts posted"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "1" "only the prior commit's comment was superseded"
hidden_own=0
for node in NODE901 NODE902 NODE903; do
	grep -q "$node" "$bin/log" && hidden_own=$((hidden_own + 1))
done
assert_equals "$hidden_own" "0" "no part of the new chain was hidden"
rm -rf "$sess" "$bin"

echo "Test 20: a write that fails partway through a chain is reported, not swallowed"
# Nothing can make a multi-comment post atomic. What the script owes the caller
# is an honest account of where it stopped, naming the part, so the orphans left
# on the pull request can be recognised for what they are. Reporting `posted`
# here would be the worst outcome: a verdict the orchestrator relays as landed
# and a reader never sees.
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
# Tail-first ordering means create #1 is part 3 and create #2 is part 2.
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID_SEQ="$bin/seq" \
	MOCK_CREATE_FAIL_AT=2 MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "a failed create is an error, not a post"
msg=$(echo "$result" | jq -r '.message')
if grep -qF "part 2 of 3" <<<"$msg"; then
	echo "  PASS: the message names the part that failed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the failure does not say where it stopped: '$msg'"
	FAIL=$((FAIL + 1))
fi
# The head must not exist: it is written last precisely so it cannot outlive a
# broken tail, and this is the case that guarantee is for.
if ! grep -qF "Review Council: REQUEST CHANGES" "$bin/log"; then
	echo "  PASS: the head was never posted over an incomplete chain"
	PASS=$((PASS + 1))
else
	echo "  FAIL: a verdict was posted summarising findings that never landed"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 21: a failed update of an existing part is reported"
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
echo "a stale prior part body" >"$bin/stale.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_GETBODY="$bin/stale.md" MOCK_UPDATE_RC=1 \
	MOCK_PARTS="901\tNODE901\t1\n902\tNODE902\t2\n903\tNODE903\t3\n" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "a failed update is an error"
if echo "$result" | jq -r '.message' | grep -qF "part 3 of 3"; then
	echo "  PASS: the first part attempted is the one named"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the failing part is not identified"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 22: a single-comment create failure still reports an error"
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_CREATE_RC=1 MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error"
if echo "$result" | jq -r '.message' | grep -qiF "failed to create"; then
	echo "  PASS: the message says the create failed"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the create failure is not described"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 23: substituting the part links never pushes the head over the limit"
# gh_apply_part_links rewrites the head AFTER the renderer sized it against the
# limit, so it is the one place a body can grow past what was measured. When it
# would, the links are dropped rather than the findings. Asserted as the
# invariant rather than by arranging the exact overflow, because the margin
# depends on fixture sizes that will drift.
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh "$bin"
PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID_SEQ="$bin/seq" MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send >/dev/null 2>&1
head_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
if [[ "$head_bytes" -le 12000 ]]; then
	echo "  PASS: the substituted head still fits the limit ($head_bytes <= 12000)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: substitution pushed the head over the limit ($head_bytes)"
	FAIL=$((FAIL + 1))
fi
# Either real links or the invisible placeholder - never a half-written line.
if grep -qF "[part 2](" "$sess/comment-body.md" || grep -qF "review-council:part-links" "$sess/comment-body.md"; then
	echo "  PASS: the head carries links or the invisible placeholder, nothing partial"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the substitution point was left in an intermediate state"
	FAIL=$((FAIL + 1))
fi
# The invariant above holds whether or not the guard exists, because a head with
# room to spare satisfies it either way. So drive the overflow itself: re-render
# to recover the head as the renderer sized it, then re-run with the limit set to
# exactly that. The packer fills part 1 identically — the finding that did not
# fit the wider budget does not fit a tighter one — so the head comes back at the
# limit to the byte, and the links have nowhere to go.
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # dry-run: the head carries the placeholder again
exact=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
sed "s/^- Comment limit: .*/- Comment limit: ${exact}/" "$sess/tracking.md" >"$sess/tracking.next"
mv "$sess/tracking.next" "$sess/tracking.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log2" MOCK_FIND="" MOCK_NEWID_SEQ="$bin/seq2" MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "parts" "3" "still a chain, so the links are still attempted"
tight_bytes=$(wc -c <"$sess/comment-body.md" | tr -d ' ')
if [[ "$tight_bytes" -le "$exact" ]]; then
	echo "  PASS: the head at the exact limit was not grown past it ($tight_bytes <= $exact)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: substitution pushed the head over the limit ($tight_bytes > $exact)"
	FAIL=$((FAIL + 1))
fi
# Navigation is what yields: the parts are adjacent in the thread regardless,
# and the placeholder renders as nothing.
if grep -qF "review-council:part-links" "$sess/comment-body.md" && ! grep -qF "[part 2](" "$sess/comment-body.md"; then
	echo "  PASS: the links were dropped and the placeholder left in their place"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the links were substituted into a head with no room for them"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 24: a finding's evidence cannot impersonate the part or sha marker"
# Why author-controlled evidence can impersonate a marker, and why neither the
# bare field names nor the marker key are enough to tell them apart, is at the
# top of the listing helpers in rc-post-comment-github.sh.
#
# What this drives: the fixture's CRITICAL evidence quotes both shapes — a bare
# `part=2&sha=deadbeef` and a full
# `<!-- review-council:marker sha=deadbeef part=9 of=9 -->` — and lands in part
# 1. Matched anywhere but the marker line, part 1 is filed under part 9: its own
# comment is never matched, so the head is posted a second time while the
# original stays visible, the surplus-retire loop fires on a part number that
# does not exist, and the supersede sweep reads the head as belonging to a
# foreign commit and hides the verdict this run just wrote.
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render the parts a previous run posted
p1=$(cat "$sess/comment-body.md")
p2=$(cat "$sess/comment-body.part2.md")
p3=$(cat "$sess/comment-body.part3.md")
if grep -qF 'part=2&sha=deadbeef' "$sess/comment-body.md" &&
	grep -qF '<!-- review-council:marker sha=deadbeef part=9 of=9 -->' "$sess/comment-body.md"; then
	echo "  PASS: the head quotes a counterfeit marker above its own"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fixture no longer carries the impersonating evidence in part 1"
	FAIL=$((FAIL + 1))
fi
jq -n --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" '[
  {id:901, node_id:"NODE901", user:{login:"council-bot"}, body:$p1},
  {id:902, node_id:"NODE902", user:{login:"council-bot"}, body:$p2},
  {id:903, node_id:"NODE903", user:{login:"council-bot"}, body:$p3}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "parts" "3" "three parts re-rendered"
assert_json_field "$result" "created" "0" "part 1 matched its own comment, not a second one"
# Only the head differs: the poster substitutes the part links into it after the
# renderer wrote the placeholder the stored copy still carries.
assert_json_field "$result" "updated" "1" "the head is updated in place"
assert_json_field "$result" "unchanged" "2" "the unchanged tail parts are left alone"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "0" "no part of the current verdict was superseded"
hidden_own=0
for node in NODE901 NODE902 NODE903; do
	grep -q "$node" "$bin/log" && hidden_own=$((hidden_own + 1))
done
assert_equals "$hidden_own" "0" "no part of the current verdict was hidden as outdated"
rm -rf "$sess" "$bin"

echo "Test 25: a quoted head sha cannot pull a foreign comment into this chain"
# The same defect in the SELECTOR rather than in the capture. `is this comment
# part of the verdict for the commit under review?` was answered by searching
# the whole body for `sha=<head>`, so a prior commit's verdict whose evidence
# quotes this commit's sha is adopted as part 1 of the current chain: it is
# overwritten in place with the new verdict instead of being banner-stamped and
# folded away, which is what a superseded verdict is owed.
sess=$(mktemp -d)
make_review_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render to learn this run's head sha
# Same extraction, same guard as Test 12: quoting an empty sha is quoting
# nothing, and this whole test is about what the quote does.
head_sha=$(sed -n 's/.*review-council:marker sha=\([^ ]*\).*/\1/p' "$sess/comment-body.md")
if [[ -n "$head_sha" ]]; then
	echo "  PASS: this run's head sha was read out of the rendered marker"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no head sha extracted; the comment below quotes nothing"
	FAIL=$((FAIL + 1))
fi
# The quoted block carries a counterfeit marker for this run's sha at column 0,
# above the comment's own marker. That is stricter than anything the renderer
# can currently produce — `evidence_block` indents quoted source by two spaces,
# so no author text reaches column 0 today — and deliberately so: the listings
# must be the thing that rejects it, not an indent applied in another file.
# Reading the LAST marker line is what makes the real one win.
jq -n --arg sha "$head_sha" '[
  {id:808, node_id:"NODE808", user:{login:"council-bot"},
   body:"Prior verdict.\n\n```\nreq, _ := http.NewRequest(\"GET\", \"/compare?sha=\($sha)\", nil)\n<!-- review-council:marker sha=\($sha) part=1 of=1 -->\n```\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->\n"}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "the prior commit's comment is not this run's part 1"
assert_json_field "$result" "created" "1" "this run's verdict is posted as a new comment"
assert_json_field "$result" "updated" "0" "the prior verdict is not overwritten in place"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "1" "the prior verdict is superseded instead"
if grep -q 'NODE808' "$bin/log"; then
	echo "  PASS: the prior verdict was folded away as outdated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the prior verdict was left current"
	FAIL=$((FAIL + 1))
fi
rm -rf "$sess" "$bin"

echo "Test 26: a chain whose head sha is unresolvable still matches part by part"
# `sha=` is not always hex. When the review root has no resolvable HEAD the
# renderer leaves RC_HEAD_SHA empty and the marker reads `sha=unknown`, which
# every part of the chain then carries. A capture that insists on hex reads
# nothing from those markers: every part falls back to part 1, so parts 2..N are
# created again on every run while part 1 is written over whichever comment last
# landed in that slot, and the supersede sweep — reading an empty sha for
# comments it just posted — folds the whole fresh verdict away as outdated.
#
# The captures therefore accept exactly what the selector accepts: one
# space-delimited token, hex or not.
sess=$(mktemp -d)
make_chained_session "$sess"
rm -rf "$sess/checkout/.git" # no HEAD to resolve
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render the parts a previous run posted
if grep -qF '<!-- review-council:marker sha=unknown part=1 of=3 -->' "$sess/comment-body.md"; then
	echo "  PASS: the marker carries a non-hex sha"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the fixture did not produce an unresolvable head sha"
	FAIL=$((FAIL + 1))
fi
p1=$(cat "$sess/comment-body.md")
p2=$(cat "$sess/comment-body.part2.md")
p3=$(cat "$sess/comment-body.part3.md")
jq -n --arg p1 "$p1" --arg p2 "$p2" --arg p3 "$p3" '[
  {id:901, node_id:"NODE901", user:{login:"council-bot"}, body:$p1},
  {id:902, node_id:"NODE902", user:{login:"council-bot"}, body:$p2},
  {id:903, node_id:"NODE903", user:{login:"council-bot"}, body:$p3}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "parts" "3" "three parts re-rendered"
assert_json_field "$result" "created" "0" "no part is posted a second time"
assert_json_field "$result" "updated" "1" "the head is updated in place"
assert_json_field "$result" "unchanged" "2" "parts 2 and 3 are matched to their own comments"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "0" "no part of the current verdict was superseded"
hidden_own=0
for node in NODE901 NODE902 NODE903; do
	grep -q "$node" "$bin/log" && hidden_own=$((hidden_own + 1))
done
assert_equals "$hidden_own" "0" "no part of the current verdict was hidden as outdated"
rm -rf "$sess" "$bin"

echo "Test 27: an edit below the marker does not orphan a council comment"
# A maintainer can edit the bot's comment, and appending a note to one is an
# ordinary thing to do. That pushes the marker off the end of the body, so a
# listing that reads only the FINAL line stops recognising the comment: the
# chain's head is posted again beside the edited copy, and the sweep never
# retires the edited copy of a prior commit's verdict, so the pull request ends
# up carrying two live verdicts and keeps one of them forever. Base behaviour
# updated the comment in place, so both listings scan back to the LAST line that
# opens a marker instead.
#
# That scan keeps the anti-impersonation property Test 24 asserts, and this
# fixture proves the two compose: part 1 quotes a counterfeit marker in its
# evidence, which is always ABOVE the real one, so scanning from the end reaches
# the real marker first either way.
sess=$(mktemp -d)
make_chained_session "$sess"
bin=$(mktemp -d)
make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1 # render the parts a previous run posted
p1=$(cat "$sess/comment-body.md")
p2=$(cat "$sess/comment-body.part2.md")
p3=$(cat "$sess/comment-body.part3.md")
note='

Edited by a maintainer: tracking the retry loop in #412.
'
jq -n --arg p1 "$p1$note" --arg p2 "$p2" --arg p3 "$p3" --arg note "$note" '[
  {id:901, node_id:"NODE901", user:{login:"council-bot"}, body:$p1},
  {id:902, node_id:"NODE902", user:{login:"council-bot"}, body:$p2},
  {id:903, node_id:"NODE903", user:{login:"council-bot"}, body:$p3},
  {id:808, node_id:"NODE808", user:{login:"council-bot"},
   body:("a prior commit\n\n<!-- review-council:marker sha=deadbeefdeadbeef part=1 of=1 -->\n" + $note)}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "created" "0" "the edited head is still this run's part 1"
assert_json_field "$result" "updated" "1" "the edited head is updated in place"
assert_json_field "$result" "unchanged" "2" "the untouched tail parts are still matched"
sup=$(echo "$result" | jq '.superseded')
assert_equals "$sup" "1" "the edited prior verdict is still swept"
if grep -q 'NODE808' "$bin/log"; then
	echo "  PASS: the edited prior verdict was folded away as outdated"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the edited prior verdict was left current beside the new one"
	FAIL=$((FAIL + 1))
fi
hidden_own=0
for node in NODE901 NODE902 NODE903; do
	grep -q "$node" "$bin/log" && hidden_own=$((hidden_own + 1))
done
assert_equals "$hidden_own" "0" "no part of the current verdict was hidden as outdated"
rm -rf "$sess" "$bin"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
