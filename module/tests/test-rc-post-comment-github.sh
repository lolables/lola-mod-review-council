#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-github.sh"
# shellcheck source=module/tests/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

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
# (file get-body cats), MOCK_NEWID (create stdout), MOCK_LIST (list-council %b).
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
sess=$(mktemp -d); make_review_session "$sess"
result=$(bash "$SCRIPT" "$sess" 2>/dev/null)
assert_json_field "$result" "status" "rendered" "status is rendered (dry-run)"
grep -qF "<!-- review-council:marker sha=" "$sess/comment-body.md" && { echo "  PASS: body rendered"; PASS=$((PASS+1)); } || { echo "  FAIL: no body"; FAIL=$((FAIL+1)); }
rm -rf "$sess"

# Test 2: --send, no existing comment -> create, superseded 0
echo "Test 2: send creates a new comment"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="777" MOCK_LIST="" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "posted" "status is posted"
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded'); [[ "$sup" -eq 0 ]] && { echo "  PASS: superseded=0"; PASS=$((PASS+1)); } || { echo "  FAIL: superseded=$sup"; FAIL=$((FAIL+1)); }
grep -q 'issues/42/comments' "$bin/log" && grep -q -- '-f body=' "$bin/log" && { echo "  PASS: create POST issued"; PASS=$((PASS+1)); } || { echo "  FAIL: create not issued"; FAIL=$((FAIL+1)); }
rm -rf "$sess" "$bin"

# Test 3: --send, existing comment for this SHA, identical body -> unchanged
echo "Test 3: send no-op when body unchanged"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1   # pre-render deterministic body
cp "$sess/comment-body.md" "$bin/prior.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="900" MOCK_GETBODY="$bin/prior.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "unchanged" "action is unchanged"
if ! grep -q -- '-X PATCH' "$bin/log"; then echo "  PASS: no PATCH for identical body"; PASS=$((PASS+1)); else echo "  FAIL: PATCH issued"; FAIL=$((FAIL+1)); fi
rm -rf "$sess" "$bin"

# Test 4: --send, existing comment for this SHA, different body -> update
echo "Test 4: send updates in place when body differs"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
echo "stale prior body" >"$bin/stale.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="901" MOCK_GETBODY="$bin/stale.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "updated" "action is updated"
grep -q 'issues/comments/901' "$bin/log" && grep -q -- '-X PATCH' "$bin/log" && { echo "  PASS: PATCH 901"; PASS=$((PASS+1)); } || { echo "  FAIL: no PATCH 901"; FAIL=$((FAIL+1)); }
rm -rf "$sess" "$bin"

# Test 5: new commit + a prior comment on another SHA -> create + supersede
echo "Test 5: new commit supersedes prior comment"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
echo "an older council comment" >"$bin/old.md"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" MOCK_NEWID="778" \
	MOCK_LIST="808\tNODE808\tdeadbeefdeadbeef\n" MOCK_GETBODY="$bin/old.md" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "action is created"
sup=$(echo "$result" | jq '.superseded'); [[ "$sup" -eq 1 ]] && { echo "  PASS: superseded=1"; PASS=$((PASS+1)); } || { echo "  FAIL: superseded=$sup"; FAIL=$((FAIL+1)); }
if grep -q 'issues/comments/808' "$bin/log" && grep -q -- '-X PATCH' "$bin/log" && grep -q 'NODE808' "$bin/log"; then
	echo "  PASS: prior comment updated + minimized"; PASS=$((PASS+1))
else
	echo "  FAIL: supersede did not update+minimize"; FAIL=$((FAIL+1))
fi
rm -rf "$sess" "$bin"

# Test 6: find-by-sha lookup FAILS -> status error, nothing posted
echo "Test 6: lookup failure reports error"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND_RC=1 \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "error" "status is error on lookup failure"
rm -rf "$sess" "$bin"

# Test 7: gh absent -> render-only degrade even with --send
echo "Test 7: gh absent degrades to render-only"
sess=$(mktemp -d); make_review_session "$sess"
gbin=$(mktemp -d)
for f in /usr/bin/*; do n=$(basename "$f"); [[ "$n" == "gh" ]] && continue; ln -s "$f" "$gbin/$n" 2>/dev/null || true; done
result=$(PATH="$gbin" bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "rendered" "degrades to rendered when gh missing"
rm -rf "$sess" "$gbin"

# Test 8: --send WITHOUT REVIEW_COUNCIL_ALLOW_POST refuses to post (hard gate)
echo "Test 8: refuses to post without REVIEW_COUNCIL_ALLOW_POST"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh "$bin"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" MOCK_FIND="" \
	bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "status" "confirm_required" "status is confirm_required without allow-post"
if [[ ! -s "$bin/log" ]]; then echo "  PASS: gh never invoked"; PASS=$((PASS+1)); else echo "  FAIL: gh invoked despite gate"; FAIL=$((FAIL+1)); fi
rm -rf "$sess" "$bin"

# Test 9: REAL find-by-sha filter selects the comment whose marker carries this
# commit's SHA (body identical) -> unchanged. Exercises the actual
# contains(marker) and contains(sha=...) selection + get-body over real jq.
echo "Test 9: real find-by-sha filter matches this SHA (unchanged)"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh_realjq "$bin"
bash "$SCRIPT" "$sess" >/dev/null 2>&1   # render the deterministic body (marker carries head sha)
rbody=$(cat "$sess/comment-body.md")
jq -n --arg b "$rbody" '[{id:900, node_id:"NODE900", body:$b}]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "unchanged" "real filter finds the sha-matched comment"
rm -rf "$sess" "$bin"

# Test 10: REAL list-council filter supersedes ONLY marker comments on other
# SHAs, excluding a non-council comment. Exercises the capture("sha=...") regex
# and the marker filter, plus find-by-sha returning empty for an absent SHA.
echo "Test 10: real list-council filter supersedes council only, excludes non-council"
sess=$(mktemp -d); make_review_session "$sess"
bin=$(mktemp -d); make_gh_realjq "$bin"
jq -n '[
  {id:808, node_id:"NODE808", body:"old council <!-- review-council:marker sha=deadbeefdeadbeef -->"},
  {id:700, node_id:"NODE700", body:"unrelated human comment"}
]' >"$bin/comments.json"
result=$(PATH="$bin:$PATH" GH_LOG="$bin/log" GH_COMMENTS="$bin/comments.json" \
	REVIEW_COUNCIL_ALLOW_POST=1 bash "$SCRIPT" "$sess" --send 2>/dev/null)
assert_json_field "$result" "action" "created" "no sha match -> created"
sup=$(echo "$result" | jq '.superseded'); [[ "$sup" -eq 1 ]] && { echo "  PASS: superseded=1 (council only)"; PASS=$((PASS+1)); } || { echo "  FAIL: superseded=$sup"; FAIL=$((FAIL+1)); }
if grep -q 'issues/comments/808' "$bin/log" && grep -q 'NODE808' "$bin/log" && ! grep -q '700' "$bin/log"; then
	echo "  PASS: council 808 superseded, non-council 700 untouched"; PASS=$((PASS+1))
else
	echo "  FAIL: supersede touched the wrong comments"; FAIL=$((FAIL+1))
fi
rm -rf "$sess" "$bin"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
