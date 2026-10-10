#!/usr/bin/env bash
# Unit tests for scripts/lib/forge-gitlab.sh — the GitLab half of the forge
# adapter contract the batch scripts call through.
#
# The adapter's job is to answer the questions forge-github.sh answers, in the
# same shapes, from `glab api`. The comment payload matters most: comments.sh
# holds the forgery boundary and is reused unchanged, so the normalised notes
# have to carry the same trust signals (viewerDidAuthor, isMinimized) that
# GitHub's payload does. A stub glab on PATH answers every call offline and
# logs its argv, which is also how the host and project encoding are checked.
#
# shellcheck disable=SC2310 # Most cases here capture a function's exit status
# with `|| rc=$?` because the status IS what they assert; errexit being off
# inside that call is the point, not an accident.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../scripts/lib"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Read into `actual` before asserting, as test-scripts-lib.sh explains: a
# substitution nested in another command has its exit status discarded.
actual=""
rc=0
ok=no

for lib in common.sh comments.sh forge-gitlab.sh; do
	[[ -f "$LIB_DIR/$lib" ]] || {
		echo "ERROR: library not found: $LIB_DIR/$lib" >&2
		exit 1
	}
done
# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/comments.sh
source "$LIB_DIR/comments.sh"
# shellcheck source=scripts/lib/forge-gitlab.sh
source "$LIB_DIR/forge-gitlab.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The stub dispatches on the joined argv, most specific pattern first: a POST
# to notes would otherwise match the notes GET, and every subpath would match
# the bare merge request lookup. Each answer is an env var so a case sets only
# what it exercises. GLAB_LOG is per case; GLAB_ALL_LOG spans the suite.
#
# `auth status --hostname H` exits 0 only for the hosts in MOCK_LOGGED_IN
# (default: git.example.org). A host in MOCK_CONFIGURED fails the way the real
# glab fails for a config entry it cannot authenticate (no token, expired,
# unreachable); any other host fails as absent from glab's config, which the
# real glab answers locally. Every call also logs, to GLAB_TOKEN_LOG, which of
# glab's environment token variables it could see.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/glab" <<'MOCKGLAB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GLAB_LOG"
printf '%s\n' "$*" >>"$GLAB_ALL_LOG"
printf 'tokens=%s\n' "${GITLAB_TOKEN+GITLAB_TOKEN}${GITLAB_ACCESS_TOKEN+,GITLAB_ACCESS_TOKEN}${OAUTH_TOKEN+,OAUTH_TOKEN}" >>"$GLAB_TOKEN_LOG"
printf 'api_host=%s ci_autologin=%s\n' "${GITLAB_API_HOST-<unset>}" "${GLAB_ENABLE_CI_AUTOLOGIN-<unset>}" >>"$GLAB_TOKEN_LOG.api_host"
default_user='{"id":42,"username":"council"}'
case "$*" in
"auth status --hostname "*)
	case " ${MOCK_LOGGED_IN-git.example.org} " in
	*" $4 "*) exit 0 ;;
	esac
	case " ${MOCK_CONFIGURED:-} " in
	*" $4 "*) echo "  X could not authenticate to one or more of the configured GitLab instances." >&2 ;;
	*) echo "  X $4 has not been authenticated with glab; run \`glab auth login --hostname $4\` to authenticate." >&2 ;;
	esac
	exit 1
	;;
*"-X POST"*)
	prev=""
	for a in "$@"; do
		[[ "$prev" == "--input" ]] && cp "$a" "$MOCK_POSTED"
		prev="$a"
	done
	exit "${MOCK_POST_RC:-0}"
	;;
*" user")
	printf '%s' "${MOCK_USER-$default_user}"
	exit "${MOCK_USER_RC:-0}"
	;;
*merge_requests\?state=opened*)
	[[ "${MOCK_LIST_RC:-0}" -eq 0 ]] || echo "glab: 502 Bad Gateway" >&2
	printf '%s' "${MOCK_LIST:-}"
	exit "${MOCK_LIST_RC:-0}"
	;;
*/notes*)
	cat "$MOCK_NOTES"
	exit "${MOCK_NOTES_RC:-0}"
	;;
*/approvals)
	printf '%s' "${MOCK_APPROVALS:-}"
	exit "${MOCK_APPROVALS_RC:-0}"
	;;
*/commits*)
	printf '%s' "${MOCK_COMMITS:-}"
	exit "${MOCK_COMMITS_RC:-0}"
	;;
*/diffs*)
	printf '%s' "${MOCK_DIFFS:-}"
	exit "${MOCK_DIFFS_RC:-0}"
	;;
*users\?username=*)
	printf '%s' "${MOCK_USERS:-}"
	exit "${MOCK_USERS_RC:-0}"
	;;
*members/all/*)
	printf '%s' "${MOCK_MEMBER:-}"
	exit "${MOCK_MEMBER_RC:-0}"
	;;
*merge_requests/[0-9]*)
	printf '%s' "${MOCK_MR:-}"
	exit "${MOCK_MR_RC:-0}"
	;;
*) exit 1 ;;
esac
MOCKGLAB
chmod +x "$WORK/bin/glab"
PATH="$WORK/bin:$PATH"

export GLAB_LOG="$WORK/glab.log" GLAB_ALL_LOG="$WORK/glab-all.log" GLAB_TOKEN_LOG="$WORK/glab-tokens.log"
export MOCK_NOTES="$WORK/notes.json" MOCK_POSTED="$WORK/posted.json"
: >"$GLAB_ALL_LOG"

REPO="g/sub/p"
FORGE_HOST="git.example.org"
GITLAB_VIEWER_ID=42
TARGET_PR=""

# Every case starts from no canned answers and an empty per-case log, so a
# value one case set can never be what makes a later case pass.
reset_mocks() {
	local v
	for v in MOCK_USER MOCK_USER_RC MOCK_LIST MOCK_LIST_RC MOCK_NOTES_RC \
		MOCK_APPROVALS MOCK_APPROVALS_RC MOCK_COMMITS MOCK_COMMITS_RC \
		MOCK_DIFFS MOCK_DIFFS_RC MOCK_USERS MOCK_USERS_RC MOCK_MEMBER \
		MOCK_MEMBER_RC MOCK_MR MOCK_MR_RC MOCK_POST_RC MOCK_LOGGED_IN MOCK_CONFIGURED; do
		unset "$v"
	done
	: >"$GLAB_LOG"
	: >"$GLAB_TOKEN_LOG"
	: >"$GLAB_TOKEN_LOG.api_host"
	: >"$MOCK_NOTES"
	rm -f "$MOCK_POSTED"
	TARGET_PR=""
	GITLAB_VIEWER_ID=42
}

# shellcheck disable=SC2016 # the backticks are a literal markdown code span
BANNER='> **Obsolete.** Superseded by the [current Review Council verdict](https://git.example.org/g/sub/p/-/merge_requests/9#note_1) for commit `abc1234`. <!-- review-council:obsolete -->'
MARKER='<!-- review-council:marker sha=abc1234 part=1 of=1 -->'

# note <id> <author-id> <created_at> <body> [system] -> one GitLab note object.
note() {
	jq -cn --argjson id "$1" --argjson aid "$2" --arg at "$3" --arg body "$4" \
		--argjson sys "${5:-false}" \
		'{id: $id, system: $sys, body: $body, created_at: $at,
		  author: {id: $aid, username: (if $aid == 42 then "council" else "stranger" end)}}'
}

echo "Test: notes normalise into the GitHub comment shape"
reset_mocks
n_sys=$(note 1 42 "2026-10-08T14:00:00.000Z" "<!-- review-council:marker sha=sys0000 part=1 of=1 -->" true)
n_ours=$(note 2 42 "2026-10-08T13:52:36.645Z" $'## Review Council: APPROVE\n\n'"$MARKER")
n_theirs=$(note 3 43 "2026-10-08T13:00:00Z" "looks fine")
printf '[%s,%s,%s]' "$n_ours" "$n_theirs" "$n_sys" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '.comments | length' "2" "the system note is dropped"
assert_jq_str "$payload" '[.comments[].body | contains("sys0000")] | any' "false" \
	"nothing of the system note survives"
assert_jq_str "$payload" '[.comments[].viewerDidAuthor] | map(tostring) | join(",")' \
	"true,false" "author id 42 is the viewer, 43 is not"
assert_jq_str "$payload" '[.comments[].author.login] | join(",")' "council,stranger" \
	"username becomes author.login"
assert_jq_str "$payload" '[.comments[].createdAt] | join(",")' \
	"2026-10-08T13:52:36Z,2026-10-08T13:00:00Z" \
	"fractional seconds are cut; whole-second stamps are untouched"
assert_jq_str "$payload" '[.comments[].authorAssociation] | unique | join(",")' "MEMBER" \
	"every note reports MEMBER"
assert_jq_str "$payload" '[.comments[].isMinimized] | any' "false" \
	"plain notes are not minimised"
actual=$(council_verdict_for "$payload")
assert_equals "$actual" $'abc1234\t2026-10-08T13:52:36Z' \
	"council_verdict_for reads our verdict from the normalised payload"

echo ""
echo "Test: note timestamps become whole-second UTC"
# Self-managed instances answer in their configured time zone, so an offset
# stamp must land on the same instant in UTC: verdicts_since compares stamps
# as strings, and a local-time stamp would sit outside (or inside) the window
# by the offset.
reset_mocks
stamps=("2026-10-08T13:52:36.645Z" "2026-10-08T13:52:36Z"
	"2026-10-08T09:52:36.645-04:00" "2026-10-08T19:22:36+05:30"
	"2026-10-08T14:52:36+0100" "2026-10-08T22:30:00-05:00"
	"2026-10-08 13:52:36" "2026-13-45T99:99:99Z" "yesterday")
notes_json="[]"
for i in "${!stamps[@]}"; do
	one=$(note "$((i + 1))" 43 "${stamps[i]}" "note $i")
	notes_json=$(jq -c --argjson n "$one" '. + [$n]' <<<"$notes_json")
done
printf '%s' "$notes_json" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '.comments[0].createdAt' "2026-10-08T13:52:36Z" "milliseconds are cut"
assert_jq_str "$payload" '.comments[1].createdAt' "2026-10-08T13:52:36Z" "a whole-second Z stamp is unchanged"
assert_jq_str "$payload" '.comments[2].createdAt' "2026-10-08T13:52:36Z" "-04:00 moves four hours forward"
assert_jq_str "$payload" '.comments[3].createdAt' "2026-10-08T13:52:36Z" "+05:30 moves five and a half hours back"
assert_jq_str "$payload" '.comments[4].createdAt' "2026-10-08T13:52:36Z" "+0100 without a colon is read"
assert_jq_str "$payload" '.comments[5].createdAt' "2026-10-09T03:30:00Z" "an offset can roll the date over"
assert_jq_str "$payload" '[.comments[6:][].createdAt] | map(. == "") | all' "true" \
	"anything unparseable becomes empty"
assert_jq_str "$payload" '.comments | length' "9" "and the note itself is kept"

echo ""
echo "Test: the obsolete banner stands in for minimisation"
reset_mocks
n_retired=$(note 2 42 "2026-10-08T13:52:36.645Z" "$BANNER"$'\n\n## Review Council: APPROVE\n\n'"$MARKER")
printf '[%s]' "$n_retired" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '.comments[0].isMinimized' "true" "a bannered verdict is minimised"
actual=$(council_verdict_for "$payload")
assert_equals "$actual" "" "a retired verdict is not a verdict"

echo ""
echo "Test: a quoted marker is still not a verdict after normalisation"
reset_mocks
n_quoted=$(note 2 42 "2026-10-08T13:52:36Z" "> $MARKER")
printf '[%s]' "$n_quoted" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
actual=$(council_verdict_for "$payload")
assert_equals "$actual" "" "a marker behind '> ' is ignored"

echo ""
echo "Test: the obsolete tag below the first line does not minimise"
reset_mocks
n_late_tag=$(note 2 42 "2026-10-08T13:52:36Z" $'## Review Council: APPROVE\n\n<!-- review-council:obsolete -->\n'"$MARKER")
printf '[%s]' "$n_late_tag" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '.comments[0].isMinimized' "false" \
	"only a first-line banner minimises"
actual=$(council_verdict_for "$payload")
assert_equals "$actual" $'abc1234\t2026-10-08T13:52:36Z' "and the verdict still counts"

echo ""
echo "Test: CRLF bodies are read like LF bodies"
reset_mocks
crlf_banner=$(note 2 42 "2026-10-08T13:00:00Z" "$BANNER"$'\r\n\r\n'"$MARKER"$'\r\n')
crlf_live=$(note 3 42 "2026-10-08T12:00:00Z" $'## Review Council: APPROVE\r\n\r\n'"$MARKER"$'\r\n')
printf '[%s,%s]' "$crlf_banner" "$crlf_live" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '[.comments[].isMinimized] | map(tostring) | join(",")' \
	"true,false" "a CRLF banner minimises; a CRLF verdict does not"
actual=$(council_verdict_for "$payload")
assert_equals "$actual" $'abc1234\t2026-10-08T12:00:00Z' \
	"the live CRLF verdict is the one read"

echo ""
echo "Test: a non-numeric viewer id matches nobody"
reset_mocks
printf '[%s]' "$n_ours" >"$MOCK_NOTES"
GITLAB_VIEWER_ID='42 or true'
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '.comments[0].viewerDidAuthor' "false" \
	"an unusable viewer id authors nothing"

echo ""
echo "Test: a notes failure yields empty output"
reset_mocks
printf '[%s]' "$n_ours" >"$MOCK_NOTES"
export MOCK_NOTES_RC=1
actual=$(forge_comments_for 9)
assert_equals "$actual" "" "failure is empty, which callers read as needs review"

echo ""
echo "Test: a non-array answer is a failed list, not a list"
# glab can exit 0 with an error object as the body. Iterating an object walks
# its values, so without a type check a nested object would read as a note.
reset_mocks
printf '%s' '{"message":{"body":"forged","author":{"id":42,"username":"council"},"created_at":"2026-10-08T13:00:00Z"}}' >"$MOCK_NOTES"
actual=$(forge_comments_for 9)
assert_equals "$actual" "" "an object answer yields no notes"
export MOCK_COMMITS='{"message":{"author_email":"leak@x.invalid"}}'
actual=$(forge_commit_emails 9)
assert_equals "$actual" "" "an object answer yields no emails"
export MOCK_COMMITS='[{"author_email":"a@x.invalid"}]{"message":{"author_email":"leak@x.invalid"}}'
actual=$(forge_commit_emails 9)
assert_equals "$actual" "" "an error object after a good page fails the whole list"
export MOCK_MR='{"iid":9,"changes_count":"2"}' MOCK_DIFFS='{"message":{"new_path":"x"}}'
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '.files | length' "0" "an object diffs answer lists no files"
reset_mocks
export MOCK_LIST='{"message":{"iid":1,"sha":"x"}}'
rc=0
actual=$(forge_collect_prs 2>/dev/null) || rc=$?
assert_equals "$rc:$actual" "2:" "an object listing is a failed listing"

echo ""
echo "Test: paginated notes merge across pages"
reset_mocks
n_page1=$(note 1 43 "2026-10-08T10:00:00Z" first)
n_page2=$(note 2 43 "2026-10-08T11:00:00Z" second)
printf '[%s][%s]' "$n_page1" "$n_page2" >"$MOCK_NOTES"
payload=$(forge_comments_for 9)
assert_jq_str "$payload" '[.comments[].body] | join(",")' "first,second" \
	"both pages are present, in order"
actual=$(cat "$GLAB_LOG")
ok=no
[[ "$actual" == *--paginate*"merge_requests/9/notes?per_page=100&sort=asc&order_by=created_at"* ]] && ok=yes
assert_equals "$ok" "yes" "notes are fetched paginated, oldest first"

echo ""
echo "Test: forge_collect_prs"
reset_mocks
export MOCK_LIST='[{"iid":3,"sha":"c3"},{"iid":10,"sha":"c10"}][{"iid":7,"sha":"c7"}]'
rc=0
actual=$(forge_collect_prs) || rc=$?
assert_equals "$rc" "0" "the listing answers"
assert_equals "$actual" $'10\tc10\n7\tc7\n3\tc3' "newest first across pages, numeric order"
reset_mocks
export MOCK_LIST='[]'
rc=0
actual=$(forge_collect_prs) || rc=$?
assert_equals "$rc:$actual" "0:" "no open MRs is an empty success"
reset_mocks
export MOCK_LIST_RC=1
rc=0
actual=$(forge_collect_prs 2>"$WORK/stderr") || rc=$?
assert_equals "$rc" "2" "a failed listing returns 2"
actual=$(cat "$WORK/stderr")
assert_equals "$actual" "glab: 502 Bad Gateway" "glab's own stderr stays visible"
reset_mocks
export MOCK_LIST='<html>gateway</html>'
rc=0
actual=$(forge_collect_prs 2>/dev/null) || rc=$?
assert_equals "$rc" "2" "an unparseable listing returns 2"
reset_mocks
TARGET_PR=5
export MOCK_MR_RC=1
rc=0
actual=$(forge_collect_prs) || rc=$?
assert_equals "$rc:$actual" "1:" "a missing named MR returns 1"
reset_mocks
TARGET_PR=5
export MOCK_MR='{"iid":"five","sha":"abc"}'
rc=0
actual=$(forge_collect_prs) || rc=$?
assert_equals "$rc" "1" "a non-numeric iid returns 1"
reset_mocks
TARGET_PR=5
export MOCK_MR='{"iid":5,"sha":"abc1234"}'
rc=0
actual=$(forge_collect_prs) || rc=$?
assert_equals "$rc:$actual" $'0:5\tabc1234' "a named MR yields one line"

echo ""
echo "Test: forge_member_can_write fails closed"
check_member() { # expected-rc label [login]
	rc=0
	forge_member_can_write "${3-alice}" || rc=$?
	ok=no
	[[ "$rc" -eq 0 ]] && ok=yes
	assert_equals "$ok" "$1" "$2"
}
reset_mocks
export MOCK_USERS='[{"id":77,"username":"alice"}]' MOCK_MEMBER='{"access_level":30}'
check_member yes "Developer (30) may write"
actual=$(cat "$GLAB_LOG")
ok=no
[[ "$actual" == *"users?username=alice"* && "$actual" == *"projects/g%2Fsub%2Fp/members/all/77"* ]] && ok=yes
assert_equals "$ok" "yes" "the user id is resolved, then looked up as a project member"
export MOCK_MEMBER='{"access_level":40}'
check_member yes "Maintainer (40) may write"
export MOCK_MEMBER='{"access_level":20}'
check_member no "Reporter (20) may not"
export MOCK_MEMBER='{"access_level":"40; x"}'
check_member no "a non-numeric access level is refused"
export MOCK_MEMBER='{"access_level":40}' MOCK_MEMBER_RC=1
check_member no "a failed member lookup is refused"
unset MOCK_MEMBER_RC
export MOCK_USERS_RC=1
check_member no "a failed user lookup is refused"
unset MOCK_USERS_RC
export MOCK_USERS='[]'
check_member no "an unknown user is refused"
export MOCK_USERS='[{"id":"77/../1"}]'
check_member no "a non-numeric user id is refused"
reset_mocks
export MOCK_USERS='[{"id":77}]' MOCK_MEMBER='{"access_level":50}'
check_member no "a login with a slash is refused" "a/b"
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" "" "and glab is never called for it"
check_member no "a login starting with '-' is refused" "-x"
check_member no "an empty login is refused" ""
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" "" "nor for those"

echo ""
echo "Test: forge_is_approved needs a named approver"
check_approved() { # expected label
	rc=0
	forge_is_approved 9 || rc=$?
	ok=no
	[[ "$rc" -eq 0 ]] && ok=yes
	assert_equals "$ok" "$1" "$2"
}
reset_mocks
export MOCK_APPROVALS='{"approved":true,"approved_by":[]}'
check_approved no "approved with nobody approving is vacuous"
export MOCK_APPROVALS='{"approved":true,"approved_by":[{"user":{"username":"bob"}}]}'
check_approved yes "approved with an approver is approved"
export MOCK_APPROVALS='{"approved":false,"approved_by":[{"user":{"username":"bob"}}]}'
check_approved no "an approver short of the rule is not approved"
export MOCK_APPROVALS='{"approved":true,"approved_by":[{"user":{"username":"bob"}}]}' MOCK_APPROVALS_RC=1
check_approved no "a failed lookup is not an approval"

echo ""
echo "Test: forge_commit_emails"
reset_mocks
export MOCK_COMMITS='[{"author_email":"a@x.invalid"}][{"author_email":"b@x.invalid"},{"author_email":null}]'
actual=$(forge_commit_emails 9)
assert_equals "$actual" $'a@x.invalid\nb@x.invalid' "emails from every page, nulls skipped"
export MOCK_COMMITS_RC=1
actual=$(forge_commit_emails 9)
assert_equals "$actual" "" "failure is empty"

echo ""
echo "Test: forge_pr_meta"
reset_mocks
export MOCK_MR='{"iid":9,"changes_count":"1000+","author":{"bot":true}}'
export MOCK_DIFFS='[{"new_path":"a.sh","diff":"@@"}][{"new_path":"lib/auth.go"}]'
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '.changedFiles' "1000" "'1000+' reads as 1000"
assert_jq_str "$meta" '.author.is_bot' "true" "author.bot becomes author.is_bot"
assert_jq_str "$meta" '[.files[].path] | join(",")' "a.sh,lib/auth.go" \
	"paths come from new_path across diff pages"
export MOCK_MR='{"iid":9,"changes_count":"3","author":{"bot":false}}'
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '.changedFiles' "3" "a string count is a number"
assert_jq_str "$meta" '.author.is_bot' "false" "a human author is not a bot"
export MOCK_MR='{"iid":9,"changes_count":null,"author":{}}'
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '[.changedFiles, .author.is_bot] | map(tostring) | join(",")' "0,false" \
	"null count and missing bot flag default to 0 and false"
export MOCK_MR='{"iid":9,"changes_count":"lots"}'
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '.changedFiles' "0" "an unreadable count is 0"
export MOCK_MR='{"iid":9,"changes_count":"2"}' MOCK_DIFFS_RC=1
meta=$(forge_pr_meta 9)
assert_jq_str "$meta" '[.changedFiles, (.files | length)] | map(tostring) | join(",")' "2,0" \
	"a failed diffs lookup keeps the count and lists no files"
export MOCK_MR_RC=1
actual=$(forge_pr_meta 9)
assert_equals "$actual" "" "a failed MR lookup is empty"

echo ""
echo "Test: forge_post_comment sends the body as a JSON file"
reset_mocks
body="$WORK/body.md"
for _ in $(seq 1 4000); do
	printf 'line "quoted" \\ back\ttab — ünïcode <!-- x -->\n'
done >"$body"
# $(( )) strips the padding BSD wc puts before the count.
actual=$(wc -c <"$body")
assert_equals "$((actual))" "200000" "the body is past the 128 KiB single-argument limit"
post_tmp="$WORK/tmp"
mkdir -p "$post_tmp"
rc=0
TMPDIR="$post_tmp" forge_post_comment 9 "$body" || rc=$?
assert_equals "$rc" "0" "the post succeeds"
jq -j '.body' "$MOCK_POSTED" >"$WORK/posted-body"
rc=0
cmp -s "$WORK/posted-body" "$body" || rc=$?
assert_equals "$rc" "0" "the full body arrives byte-for-byte"
actual=$(cat "$GLAB_LOG")
ok=no
[[ "$actual" == *"-X POST"* && "$actual" == *"--input "* &&
	"$actual" == *"Content-Type: application/json"* &&
	"$actual" == *"projects/g%2Fsub%2Fp/merge_requests/9/notes"* &&
	"$actual" != *"body="* ]] && ok=yes
assert_equals "$ok" "yes" \
	"posted with --input and a JSON content type, never as a field"
actual=$(find "$post_tmp" -mindepth 1 | wc -l)
assert_equals "$((actual))" "0" "the temp file is removed"
export MOCK_POST_RC=1
rc=0
TMPDIR="$post_tmp" forge_post_comment 9 "$body" || rc=$?
ok=no
[[ "$rc" -ne 0 ]] && ok=yes
assert_equals "$ok" "yes" "a failed post is non-zero"
actual=$(find "$post_tmp" -mindepth 1 | wc -l)
assert_equals "$((actual))" "0" "and the temp file is still removed"

echo ""
echo "Test: forge_pr_url and forge_pr_label"
actual=$(forge_pr_url 9)
assert_equals "$actual" "https://git.example.org/g/sub/p/-/merge_requests/9" "the MR web URL"
actual=$(forge_pr_label 9)
assert_equals "$actual" "!9" "GitLab names an MR with !"

echo ""
echo "Test: forge_auth_check"
reset_mocks
export MOCK_USER='{}'
rc=0
(forge_auth_check) 2>"$WORK/stderr" || rc=$?
assert_equals "$rc" "1" "no user id exits 1"
actual=$(cat "$WORK/stderr")
assert_equals "$actual" "glab is not authenticated for git.example.org. Run 'glab auth login --hostname git.example.org --stdin < tokenfile' with a valid token." \
	"the message names the host and the login recipe"
export MOCK_USER='{"id":42}' MOCK_USER_RC=1
rc=0
(forge_auth_check) 2>/dev/null || rc=$?
assert_equals "$rc" "1" "a failed user lookup exits 1"
reset_mocks
export MOCK_USER='{"id":"42; x"}'
rc=0
(forge_auth_check) 2>/dev/null || rc=$?
assert_equals "$rc" "1" "a non-numeric id exits 1"
reset_mocks
export MOCK_USER='{"id":0}'
rc=0
(forge_auth_check) 2>/dev/null || rc=$?
assert_equals "$rc" "1" "user id 0 is not an account"
reset_mocks
GITLAB_VIEWER_ID=""
forge_auth_check
assert_equals "$GITLAB_VIEWER_ID" "42" "success records the viewer id"
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" $'auth status --hostname git.example.org\napi --hostname git.example.org user' \
	"after asking glab, locally, whether the host is logged in"

echo ""
echo "Test: forge_auth_check contacts no host absent from glab's config"
# glab sends the stored token to whatever host it is pointed at, so the API
# lookup must never run for a host absent from glab's config.
reset_mocks
export MOCK_LOGGED_IN=""
rc=0
(forge_auth_check) 2>"$WORK/stderr" || rc=$?
assert_equals "$rc" "1" "a host absent from glab's config exits 1"
actual=$(cat "$WORK/stderr")
assert_equals "$actual" "git.example.org is not in glab's config. Run 'glab auth login --hostname git.example.org' first (non-interactively: 'glab auth login --hostname git.example.org --stdin < tokenfile'); refusing to send GitLab credentials to a host glab is not configured for." \
	"and says how to log in"
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" "auth status --hostname git.example.org" \
	"and glab was asked nothing but the auth status"
reset_mocks
export MOCK_LOGGED_IN="" MOCK_CONFIGURED="git.example.org"
rc=0
(forge_auth_check) 2>"$WORK/stderr" || rc=$?
assert_equals "$rc" "1" "a configured host glab cannot authenticate to exits 1"
actual=$(cat "$WORK/stderr")
assert_equals "$actual" "glab could not confirm a login for git.example.org (unreachable, expired, or no token stored for it). See 'glab auth status --hostname git.example.org'." \
	"with a message that does not claim the host is unconfigured"
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" "auth status --hostname git.example.org" \
	"and glab was asked nothing but the auth status"
reset_mocks
rc=0
(
	FORGE_HOST=""
	forge_auth_check
) 2>"$WORK/stderr" || rc=$?
assert_equals "$rc" "1" "an empty host exits 1"
actual=$(cat "$GLAB_LOG")
assert_equals "$actual" "" "without calling glab at all"

echo ""
echo "Test: every call targets the configured host and encoded project"
actual=$(grep -cv -- '--hostname git.example.org' "$GLAB_ALL_LOG" || true)
assert_equals "$actual" "0" "every glab call carries --hostname git.example.org"
actual=$(grep -c 'projects/' "$GLAB_ALL_LOG" || true)
ok=no
[[ "$actual" -gt 0 ]] && ok=yes
assert_equals "$ok" "yes" "project-scoped calls were made"
actual=$(grep 'projects/' "$GLAB_ALL_LOG" | grep -cv 'projects/g%2Fsub%2Fp/' || true)
assert_equals "$actual" "0" "every project path is encoded as g%2Fsub%2Fp"

echo ""
echo "Test: glab's environment tokens reach only the host they belong to"
# glab prefers GITLAB_TOKEN, GITLAB_ACCESS_TOKEN and OAUTH_TOKEN over a host's
# stored login and sends them to whichever host it is pointed at, so a
# gitlab.com token in the environment would otherwise reach a self-managed
# host. They belong to glab's default host: the first non-empty of
# GITLAB_API_HOST (verbatim), GITLAB_HOST, GITLAB_URI, GL_HOST (URLs allowed,
# ports kept), else gitlab.com. GITLAB_API_HOST, and GLAB_ENABLE_CI_AUTOLOGIN
# with CI_SERVER_*, also override explicit addressing, so no glab call (the
# gate's included) may see either at all.
#
# token_calls <forge-host> [VAR=value...] -> for an auth check and an MR
# listing run with all three token variables and the assignments exported (and
# every other host variable unset, and CI autologin switched on): "bound" when
# all three glab calls saw every token, "unbound" when none saw any, else the
# raw log; then "|redirects-unset" when no call saw GITLAB_API_HOST or
# GLAB_ENABLE_CI_AUTOLOGIN.
token_calls() {
	local host="$1" tokens redirects
	shift
	reset_mocks
	(
		FORGE_HOST="$host"
		export MOCK_LOGGED_IN="$host" MOCK_LIST='[]'
		export GITLAB_TOKEN=t GITLAB_ACCESS_TOKEN=t OAUTH_TOKEN=t
		export GLAB_ENABLE_CI_AUTOLOGIN=true CI_SERVER_HOST=ci.example CI_JOB_TOKEN=j
		unset GITLAB_API_HOST GITLAB_HOST GITLAB_URI GL_HOST
		for assignment in "$@"; do
			export "${assignment?}"
		done
		forge_auth_check
		forge_collect_prs >/dev/null
	) 2>/dev/null || echo "token_calls failed for $host" >>"$GLAB_TOKEN_LOG"
	tokens=$(cat "$GLAB_TOKEN_LOG")
	case "$tokens" in
	$'tokens=GITLAB_TOKEN,GITLAB_ACCESS_TOKEN,OAUTH_TOKEN\ntokens=GITLAB_TOKEN,GITLAB_ACCESS_TOKEN,OAUTH_TOKEN\ntokens=GITLAB_TOKEN,GITLAB_ACCESS_TOKEN,OAUTH_TOKEN') printf 'bound' ;;
	$'tokens=\ntokens=\ntokens=') printf 'unbound' ;;
	*) printf '%s' "$tokens" ;;
	esac
	redirects=$(sort -u "$GLAB_TOKEN_LOG.api_host")
	if [[ "$redirects" = "api_host=<unset> ci_autologin=<unset>" ]]; then
		printf '|redirects-unset'
	fi
}
for token_case in \
	"git.example.org||unbound|a self-managed host with no host variable set" \
	"git.example.org|GITLAB_HOST=gitlab.com|unbound|GITLAB_HOST naming another host" \
	"git.example.org|GITLAB_HOST=https://GIT.example.org/|bound|GITLAB_HOST naming the host, as a URL" \
	"gitlab.com||bound|gitlab.com with no host variable set" \
	"git.example.org|GITLAB_HOST=git.example.org:8443|unbound|GITLAB_HOST on another port" \
	"git.example.org|GITLAB_HOST=https://git.example.org:443|bound|GITLAB_HOST with https's own port" \
	"git.example.org|GITLAB_API_HOST=git.example.org GITLAB_HOST=gitlab.com|bound|GITLAB_API_HOST naming the host, over GITLAB_HOST" \
	"git.example.org|GITLAB_API_HOST=gitlab.com GITLAB_HOST=git.example.org|unbound|GITLAB_API_HOST naming another host, over GITLAB_HOST" \
	"git.example.org|GITLAB_API_HOST=https://git.example.org|unbound|a URL in GITLAB_API_HOST, which glab takes verbatim" \
	"git.example.org|GITLAB_API_HOST=git.example.org:8443|unbound|GITLAB_API_HOST on another port" \
	"git.example.org|GITLAB_API_HOST= GITLAB_HOST=git.example.org|bound|an empty GITLAB_API_HOST, which is skipped" \
	"git.example.org|GITLAB_URI=https://git.example.org/|bound|GITLAB_URI naming the host" \
	"git.example.org|GL_HOST=git.example.org|bound|GL_HOST naming the host" \
	"git.example.org|GITLAB_URI=gitlab.com GL_HOST=git.example.org|unbound|GITLAB_URI over GL_HOST" \
	"gitlab.com|GL_HOST=git.example.org|unbound|gitlab.com once GL_HOST names another host"; do
	IFS='|' read -r host assignments want label <<<"$token_case"
	read -ra assignment_list <<<"$assignments"
	actual=$(token_calls "$host" "${assignment_list[@]}")
	assert_equals "$actual" "${want}|redirects-unset" "$label"
done

echo "Test: the banner pattern is the one the GitLab poster writes against"
# rc-post-comment-gitlab.sh skips a note whose first line matches its own copy
# of this pattern, as already retired. If the two drift, the poster can stamp a
# banner this adapter does not read as collapsed, or skip a note it does not.
batch_re=$(sed -nE 's/.*test\("(\^> [^"]*review-council:obsolete[^"]*)"\).*/\1/p' "$LIB_DIR/forge-gitlab.sh" |
	sed 's/\\\\/\\/g')
poster_re=$(sed -nE "s/^RC_GL_OBSOLETE_RE='(.*)'\$/\1/p" \
	"$SCRIPT_DIR/../skills/review-council/scripts/rc-post-comment-gitlab.sh")
assert_equals "$batch_re" "$poster_re" "forge-gitlab.sh and the poster share one banner pattern"
if [[ -n "$batch_re" ]]; then
	echo "  PASS: the pattern was read out of forge-gitlab.sh"
	PASS=$((PASS + 1))
else
	echo "  FAIL: no banner pattern found in forge-gitlab.sh"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
