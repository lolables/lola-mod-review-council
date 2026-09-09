#!/usr/bin/env bash
# Unit tests for scripts/lib/*.sh — the shared library behind
# scripts/review-open-prs.sh and scripts/review-pr-status.sh.
#
# comments.sh holds pure functions over a comments payload: no gh, no globals
# beyond the marker constants. That is what makes them testable with a string
# and nothing else, and it is why the forgery boundary lives here rather than
# in a script that has to be mocked to reach it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../../scripts/lib"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

# Every case below reads the function under test into `actual` before asserting
# on it, as the rest of this tree's suites do. A command substitution nested
# inside another command has its exit status discarded (SC2312), so a reader
# that broke outright would assert against the empty string — which several of
# these cases expect, and would therefore pass while reporting nothing.
actual=""

[[ -f "$LIB_DIR/comments.sh" ]] || {
	echo "ERROR: library not found: $LIB_DIR/comments.sh" >&2
	exit 1
}
# shellcheck source=scripts/lib/comments.sh
source "$LIB_DIR/comments.sh"

[[ -f "$LIB_DIR/common.sh" ]] || {
	echo "ERROR: library not found: $LIB_DIR/common.sh" >&2
	exit 1
}
# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"

echo "Test: council_verdict_for reads our own marker at column 0"
verdict_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_for "$verdict_json")
assert_equals "$actual" $'abc1234\t2026-08-20T10:00:00Z' \
	"our marker yields sha and timestamp"

echo ""
echo "Test: a quoted marker is not a verdict"
quoted_json='{"comments":[
 {"author":{"login":"someone"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"> <!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_for "$quoted_json")
assert_equals "$actual" "" \
	"a marker behind a quote prefix is ignored"

echo ""
echo "Test: a marker we did not author is not a verdict"
foreign_json='{"comments":[
 {"author":{"login":"stranger"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_for "$foreign_json")
assert_equals "$actual" "" \
	"a foreign marker is not our verdict"
actual=$(foreign_verdict_login "$foreign_json")
assert_equals "$actual" "stranger" \
	"but it is reported as foreign"

echo ""
echo "Test: a collapsed verdict does not count"
collapsed_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":true,"viewerDidAuthor":true,
  "body":"<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_for "$collapsed_json")
assert_equals "$actual" "" \
	"collapsing a verdict forces a fresh review"

echo ""
echo "Test: CRLF bodies still match"
crlf_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"intro\r\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_for "$crlf_json")
assert_equals "$actual" $'abc1234\t2026-08-20T10:00:00Z' \
	"a web-authored CRLF body is still a verdict"

echo ""
echo "Test: rereview_requests_for accepts only a standalone command line"
req_json='{"comments":[
 {"author":{"login":"maint"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-21T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"/review-council review"},
 {"author":{"login":"quoter"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-21T11:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"> /review-council review"},
 {"author":{"login":"chatty"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-21T12:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"please run /review-council review now"}
]}'
actual=$(rereview_requests_for "$req_json" "" | wc -l | tr -d ' ')
assert_equals "$actual" "1" \
	"only the standalone request counts"
actual=$(rereview_requests_for "$req_json" "" | cut -f1)
assert_equals "$actual" "maint" \
	"and it is attributed to its author"

echo ""
echo "Test: verdicts_since counts only our verdicts inside the window"
actual=$(verdicts_since "$verdict_json" "2026-08-20T09:00:00Z")
assert_equals "$actual" "1" \
	"a verdict inside the window counts"
actual=$(verdicts_since "$verdict_json" "2026-08-20T11:00:00Z")
assert_equals "$actual" "0" \
	"a verdict before the window does not"

echo ""
echo "Test: declined_in_window sees the decline reply we already posted"
# This reader answers with an exit status rather than on stdout, so each case
# captures the status the way test-rc-forge-adapters.sh does and asserts on it.
# It carries the OTHER marker key: a decline must never read as a verdict, so
# the two are tested against their own fixtures rather than a shared one.
declined_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-21T10:30:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"Deferred to the next slot.\n\n<!-- review-council:rate-limited until=2026-08-21T11:00:00Z -->"}
]}'
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
declined_in_window "$declined_json" "2026-08-21T10:00:00Z" || rc=$?
assert_equals "$rc" "0" "our reply inside the window is a decline"

echo ""
echo "Test: a decline older than the window does not suppress a fresh reply"
# The window is what makes the reply at-most-once per hour rather than once
# ever. A reply that has aged out has to stop counting, or a PR deferred today
# is never told again.
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
declined_in_window "$declined_json" "2026-08-21T11:00:00Z" || rc=$?
assert_equals "$rc" "1" "a reply before the window start does not count"

echo ""
echo "Test: a decline marker we did not author does not count"
# Same forgery boundary as the verdict marker, and the same reason: the key is
# public. Reading a stranger's rate-limit comment as our own reply would let
# anyone silence the notice this PR is owed.
foreign_declined_json='{"comments":[
 {"author":{"login":"stranger"},"createdAt":"2026-08-21T10:30:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:rate-limited until=2026-08-21T11:00:00Z -->"}
]}'
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
declined_in_window "$foreign_declined_json" "2026-08-21T10:00:00Z" || rc=$?
assert_equals "$rc" "1" "a foreign rate-limit marker is not our reply"

echo ""
echo "Test: a quoted decline marker does not count"
# "Quote reply" copies the marker behind a "> " prefix, which is why this
# reader anchors at column 0 like the verdict one.
quoted_declined_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-21T10:30:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"> <!-- review-council:rate-limited until=2026-08-21T11:00:00Z -->"}
]}'
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
declined_in_window "$quoted_declined_json" "2026-08-21T10:00:00Z" || rc=$?
assert_equals "$rc" "1" "a marker behind a quote prefix is not a reply"

echo ""
echo "Test: require_commands exits 1 naming a missing binary"
# require_commands calls `exit`, not `return` (see its comment in common.sh),
# so it is run inside a command substitution here: that is its own subshell,
# and the exit only ends the subshell rather than this suite.
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
out=$(require_commands definitely-not-a-real-binary-xyz 2>&1) || rc=$?
assert_equals "$rc" "1" "a missing binary exits 1"
assert_equals "$out" "Required command not found: definitely-not-a-real-binary-xyz" \
	"the message names the missing binary"

echo ""
echo "Test: require_commands reports only the first of several missing binaries"
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
out=$(require_commands definitely-not-a-real-binary-xyz another-missing-binary-abc 2>&1) || rc=$?
assert_equals "$rc" "1" "still exits 1"
assert_equals "$out" "Required command not found: definitely-not-a-real-binary-xyz" \
	"only the first missing binary is named"

echo ""
echo "Test: require_commands exits 0 and prints nothing when every binary exists"
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
out=$(require_commands bash jq 2>&1) || rc=$?
assert_equals "$rc" "0" "binaries that exist exit 0"
assert_equals "$out" "" "and nothing is printed"

[[ -f "$LIB_DIR/prs.sh" ]] || {
	echo "ERROR: library not found: $LIB_DIR/prs.sh" >&2
	exit 1
}
# shellcheck source=scripts/lib/prs.sh
source "$LIB_DIR/prs.sh"

# A gh that answers from shell variables instead of the network. prs.sh calls
# `gh` as a bare command, so a shell function of that name takes precedence
# over anything on PATH — which is the whole mock, with no bin directory to
# build and no PATH to juggle. Anything not declared below returns non-zero,
# the "the lookup answered nothing" case each caller must survive.
STUB_COMMENTS_DIR=""
gh() {
	case "$*" in
	*"--json comments"*)
		[[ -n "$STUB_COMMENTS_DIR" && -f "$STUB_COMMENTS_DIR/pr-$3.json" ]] || {
			printf '{"comments":[]}'
			return 0
		}
		cat "$STUB_COMMENTS_DIR/pr-$3.json"
		;;
	*"pr list"*)
		[[ "${STUB_LIST_FAILS:-0}" -eq 0 ]] || return 1
		printf '2\tbbbbbbb\n1\taaaaaaa\n'
		;;
	*"--json number,headRefOid"*)
		[[ "${STUB_VIEW_FAILS:-0}" -eq 0 ]] || return 1
		printf '%s\tccccccc\n' "$3"
		;;
	*"--json reviewDecision"*)
		[[ -n "${STUB_DECISIONS:-}" ]] || return 1
		awk -F'\t' -v pr="$3" '$1 == pr { print $2 }' <<<"$STUB_DECISIONS"
		;;
	*) return 1 ;;
	esac
}
STUB_DECISIONS=""

echo ""
echo "Test: resolve_target accepts the GitHub PR URL spellings people paste"
for url_case in \
	"https://github.com/acme/widgets/pull/12	acme/widgets	12" \
	"http://www.github.com/acme/widgets/pull/8	acme/widgets	8" \
	"github.com/acme/widgets/pull/3	acme/widgets	3" \
	"https://github.com/acme/widgets/pull/5/files	acme/widgets	5" \
	"https://github.com/acme/my.repo_1-x/pull/7	acme/my.repo_1-x	7"; do
	IFS=$'\t' read -r url want_repo want_pr <<<"$url_case"
	REPO=""
	resolve_target "$url"
	assert_equals "${REPO}#${TARGET_PR}" "${want_repo}#${want_pr}" \
		"$url -> $want_repo #$want_pr"
done

echo ""
echo "Test: resolve_target refuses a URL that is not a github.com PR URL"
# The host used to be unanchored, so `github.com/o/r/pull/1` matched anywhere
# in the string. A mirror, a redirector, a non-web scheme or a sentence with a
# link in it therefore resolved to a github.com repository the operator never
# named — and this tool comments publicly on whatever comes out of here.
for bad in \
	"https://mygithub.com/owner/repo/pull/7" \
	"https://evil.com/github.com/attacker/repo/pull/1" \
	"ftp://github.com/acme/widgets/pull/9" \
	"see https://github.com/acme/widgets/pull/5 please" \
	"https://github.com.evil.tld/acme/widgets/pull/3" \
	"github.com/../../pull/4" \
	"https://github.com/acme/../pull/4"; do
	rc=0
	REPO=""
	# The rejection paths call `exit 2`; the command substitution is the
	# subshell that contains it, so the suite survives to assert on it.
	# shellcheck disable=SC2310 # A non-zero exit IS the answer this case asserts on.
	actual=$(resolve_target "$bad" 2>&1) || rc=$?
	assert_equals "$rc" "2" "refused: $bad"
done

echo ""
echo "Test: resolve_target keeps an explicit --repo that agrees with the URL"
REPO="acme/widgets"
resolve_target "https://github.com/acme/widgets/pull/4"
assert_equals "$REPO" "acme/widgets" "agreeing spellings are not a conflict"

echo ""
echo "Test: resolve_target refuses an explicit --repo the URL contradicts"
rc=0
REPO="acme/widgets"
# shellcheck disable=SC2310 # A non-zero exit IS the answer this case asserts on.
actual=$(resolve_target "https://github.com/other/repo/pull/4" 2>&1) || rc=$?
assert_equals "$rc" "2" "a contradicting --repo and URL is an error"

echo ""
echo "Test: collect_prs separates a broken lookup from an empty one"
# The distinction the driver's exit code rests on. collect_prs is always read
# through `$(...)`, and bash unsets errexit inside that subshell without
# `inherit_errexit` — which this tree does not set — so the return value is the
# only channel a failure has.
REPO="acme/widgets"
TARGET_PR=""
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
actual=$(collect_prs) || rc=$?
assert_equals "$rc" "0" "a listing that answers returns 0"
assert_equals "$actual" "$(printf '2\tbbbbbbb\n1\taaaaaaa')" "and yields the PRs"

rc=0
STUB_LIST_FAILS=1
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
actual=$(collect_prs) || rc=$?
STUB_LIST_FAILS=0
assert_equals "$rc" "2" "a failed listing returns 2, not an empty success"

rc=0
TARGET_PR="42"
STUB_VIEW_FAILS=1
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
actual=$(collect_prs) || rc=$?
STUB_VIEW_FAILS=0
TARGET_PR=""
assert_equals "$rc" "1" "a named PR that cannot be read returns 1"

echo ""
echo "Test: classify_prs publishes its arrays to the CALLER"
# `declare -A` inside a function is LOCAL to that function in bash, so a
# classifier that declared these itself would hand every caller an empty map
# and nothing would say so. This is the case that catches that.
STUB_COMMENTS_DIR=$(mktemp -d)
cat >"$STUB_COMMENTS_DIR/pr-1.json" <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"}
]}
JSON
cat >"$STUB_COMMENTS_DIR/pr-2.json" <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-02T00:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=not-a-sha-garbage part=1 of=1 -->"}
]}
JSON
cat >"$STUB_COMMENTS_DIR/pr-3.json" <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=0000001 part=1 of=1 -->"}
]}
JSON
REPO="acme/widgets"
TARGET_PR=""
WINDOW_START="$(jq -rn '(now - 3600) | todate')"
classify_prs "$(printf '1\taaaaaaa\n2\tbbbbbbb\n3\tccccccc\n4\tddddddd')"

assert_equals "${REVIEWED_SHA[1]-NO-SUCH-KEY}" "aaaaaaa" \
	"the caller reads the sha classify_prs recorded"
assert_equals "${REVIEWED_AT[1]-NO-SUCH-KEY}" "2026-08-20T10:00:00Z" \
	"and the timestamp beside it"
assert_jq_str "${COMMENTS_JSON[1]-}" '.comments[0].author.login' "council" \
	"and the timeline it fetched"
assert_equals "${SKIPPED[*]}" "1" "a verdict at head is skipped"
assert_equals "${STALE[*]}" "3" "a verdict at an older commit is stale"

echo ""
echo "Test: an unparseable marker records neither a sha nor a time"
# A sha that is not a sha is not a verdict, so the PR is unreviewed — and the
# timestamp has to go with it. Reporting a PR as never reviewed while showing
# a review time next to it describes a state that never existed.
assert_equals "${REVIEWED_SHA[2]-NO-SUCH-KEY}" "" "the garbage sha is not stored"
assert_equals "${REVIEWED_AT[2]-NO-SUCH-KEY}" "" "and neither is its timestamp"
assert_equals "${UNREVIEWED[*]}" "2 4" "both unusable verdicts are unreviewed"

echo ""
echo "Test: a second classify_prs leaves nothing of the first behind"
# The driver calls this once. Nothing in the contract says a caller must, and
# a stale key here would report a PR that is not in the list it was given.
classify_prs "$(printf '1\taaaaaaa')"
assert_equals "${!REVIEWED_SHA[*]}" "1" "only the second call's PRs have a sha"
assert_equals "${!REVIEWED_AT[*]}" "1" "only the second call's PRs have a time"
assert_equals "${!COMMENTS_JSON[*]}" "1" "only the second call's timelines remain"
assert_equals "${UNREVIEWED[*]-}" "" "the first call's unreviewed PRs are gone"
assert_equals "${STALE[*]-}" "" "and its stale ones"
assert_equals "${SKIPPED[*]}" "1" "leaving exactly what the second call found"

rm -rf "$STUB_COMMENTS_DIR"
STUB_COMMENTS_DIR=""

echo ""
echo "Test: approved_pr reads GitHub's own review decision"
# reviewDecision is the forge's summary of the human reviews on a PR. Only
# APPROVED is an approval: the other two values it reports both mean the PR is
# still waiting on someone.
REPO="acme/widgets"
STUB_DECISIONS=$'1\tAPPROVED\n2\tCHANGES_REQUESTED\n3\tREVIEW_REQUIRED'
for decision_case in "1	0	APPROVED is an approval" \
	"2	1	CHANGES_REQUESTED is not" \
	"3	1	REVIEW_REQUIRED is not" \
	"4	1	a PR the forge reports no decision for is not approved"; do
	IFS=$'\t' read -r probe_pr want_rc label <<<"$decision_case"
	rc=0
	# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
	approved_pr "$probe_pr" || rc=$?
	assert_equals "$rc" "$want_rc" "$label"
done

echo ""
echo "Test: a review-decision lookup that fails is not an approval"
# The fail-open rule this whole library runs on: an unanswered gh call means
# "review it", because the cost of being wrong is one duplicate review, while
# the cost of the other answer is a PR that is never reviewed and never
# reported as unreviewed either.
STUB_DECISIONS=""
rc=0
# shellcheck disable=SC2310 # The exit status IS the answer this case asserts on.
approved_pr 1 || rc=$?
assert_equals "$rc" "1" "a broken lookup fails open to reviewing"

echo ""
echo "Test: classify_prs sets approved PRs aside only when the caller asks"
# IGNORE_APPROVED is the caller's, and unset must mean "review them": this
# library is shared with the read-only status script, which reports on every
# open PR and must not silently lose the approved ones.
REPO="acme/widgets"
TARGET_PR=""
WINDOW_START="$(jq -rn '(now - 3600) | todate')"
STUB_DECISIONS=$'2\tAPPROVED'
IGNORE_APPROVED=1
classify_prs "$(printf '1\taaaaaaa\n2\tbbbbbbb')"
assert_equals "${IGNORED_APPROVED[*]}" "2" "the approved PR is set aside"
assert_equals "${UNREVIEWED[*]}" "1" "and never reaches the review buckets"

IGNORE_APPROVED=0
classify_prs "$(printf '1\taaaaaaa\n2\tbbbbbbb')"
assert_equals "${IGNORED_APPROVED[*]-}" "" "unset, the decision is not consulted"
assert_equals "${UNREVIEWED[*]}" "1 2" "and both PRs are queued"
STUB_DECISIONS=""

echo ""
echo "Test: naming one PR overrides the approval filter"
# The same rule the author deny-list follows: batch triage does not apply to a
# PR the operator named.
TARGET_PR="2"
STUB_DECISIONS=$'2\tAPPROVED'
IGNORE_APPROVED=1
classify_prs "$(printf '2\tbbbbbbb')"
assert_equals "${IGNORED_APPROVED[*]-}" "" "an explicit target is not filtered out"
assert_equals "${UNREVIEWED[*]}" "2" "it is queued like any other"
STUB_DECISIONS=""
IGNORE_APPROVED=0
TARGET_PR=""

echo ""
echo "Test: council_verdict_word reads the heading from a single-part verdict"
single_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\nbody\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$single_json")
assert_equals "$actual" "APPROVE" \
	"a single-part verdict yields its word"

echo ""
echo "Test: a split verdict is read from part 1, not from the newest comment"
# The heading only exists in part 1. council_verdict_for takes the NEWEST
# comment, which for a split verdict is the last part — so a naive reader
# returns nothing for exactly the biggest reviews.
split_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🔴 Review Council: REQUEST CHANGES\n\nfindings\n\n<!-- review-council:marker sha=abc1234 part=1 of=3 -->"},
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:01Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"more findings\n\n<!-- review-council:marker sha=abc1234 part=2 of=3 -->"},
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:02Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"last findings\n\n<!-- review-council:marker sha=abc1234 part=3 of=3 -->"}
]}'
actual=$(council_verdict_word "$split_json")
assert_equals "$actual" "REQUEST CHANGES" \
	"part 1 carries the verdict of a split review"

echo ""
echo "Test: a forged heading from another account is not our verdict"
forged_json='{"comments":[
 {"author":{"login":"stranger"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$forged_json")
assert_equals "$actual" "" \
	"a heading we did not author yields nothing"

echo ""
echo "Test: a verdict comment with no heading yields nothing, not an error"
noheading_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"body with no heading\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$noheading_json")
assert_equals "$actual" "" \
	"a missing heading is empty, not a failure"

echo ""
echo "Test: an unrecognised verdict word passes through verbatim"
future_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟣 Review Council: DEFERRED PENDING SPEC\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$future_json")
assert_equals "$actual" "DEFERRED PENDING SPEC" \
	"an unfamiliar verdict is shown, not normalised away"

echo ""
echo "Test: no comment carries part= at all, so the pre-ec0dbbc shape falls back"
# Before ec0dbbc (2026-08-17) the marker carried no part key. The fallback is
# guarded on "no comment in the timeline carries part=" rather than "part=1 was
# not found", so this older shape still yields a verdict.
oldshape_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 -->"}
]}'
actual=$(council_verdict_word "$oldshape_json")
assert_equals "$actual" "APPROVE" \
	"a marker with no part= key at all still falls back to the newest"

echo ""
echo "Test: part=1 minimised does not fall back onto a heading-less tail part"
# part= IS present in this timeline (parts 2 and 3), so the guard correctly
# declines to fall back — the honest answer here is empty, not part 3's body.
# Part 3 is deliberately given a heading-shaped line of its own (real chained
# verdicts never do this — only part 1 carries one) so that a guard which
# fails to fire is caught by a wrong non-empty answer, not by an empty one
# that would also occur here for the unrelated reason that a real tail part
# carries no heading to find.
minimised_part1_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":true,"viewerDidAuthor":true,
  "body":"## 🔴 Review Council: REQUEST CHANGES\n\nfindings\n\n<!-- review-council:marker sha=abc1234 part=1 of=3 -->"},
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:01Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"more findings\n\n<!-- review-council:marker sha=abc1234 part=2 of=3 -->"},
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:02Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟡 Review Council: SHOULD NOT SURFACE\n\nlast findings\n\n<!-- review-council:marker sha=abc1234 part=3 of=3 -->"}
]}'
actual=$(council_verdict_word "$minimised_part1_json")
assert_equals "$actual" "" \
	"a minimised part 1 is not replaced by a heading-less tail part"

echo ""
echo "Test: CRLF line endings around the marker and the heading still parse"
crlf_word_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\r\n\r\nbody\r\n\r\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$crlf_word_json")
assert_equals "$actual" "APPROVE" \
	"a web-authored CRLF body around both the heading and the marker still parses"

echo ""
echo "Test: two verdicts for different SHAs both carry part=1, the newer wins"
two_shas_json='{"comments":[
 {"author":{"login":"council"},"createdAt":"2026-08-20T09:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🔴 Review Council: REQUEST CHANGES\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"},
 {"author":{"login":"council"},"createdAt":"2026-08-20T11:00:00Z",
  "isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$two_shas_json")
assert_equals "$actual" "APPROVE" \
	"the newer sha's verdict word wins"

echo ""
echo "Test: council_verdict_any_for counts another account's verdict under scope all"
# The fleet case: the council posts from a bot account, or from a second
# machine, so viewerDidAuthor is false for every verdict it left behind. Under
# the scope this reader exists for, that verdict counts and says who posted it.
any_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_any_for "$any_foreign_json" "all")
assert_equals "$actual" $'abc1234\t2026-08-20T10:00:00Z\tcouncil-bot\t0' \
	"scope all yields the sha, the time, the author and not-ours"

echo ""
echo "Test: the gated reader still refuses what the scoped one accepts"
# The boundary the driver stands on. council_verdict_any_for sits BESIDE
# council_verdict_for rather than in place of it: a marker is public, so a
# reader that spends money on what it finds must keep refusing foreign ones.
actual=$(council_verdict_for "$any_foreign_json")
assert_equals "$actual" "" \
	"council_verdict_for still declines a marker this account did not post"

echo ""
echo "Test: council_verdict_any_for reports our own verdict as ours"
actual=$(council_verdict_any_for "$verdict_json" "all")
assert_equals "$actual" $'abc1234\t2026-08-20T10:00:00Z\tcouncil\t1' \
	"a verdict this account posted carries viewerDidAuthor as 1"

echo ""
echo "Test: a named login counts only that login's verdicts"
two_accounts_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"},
 {"author":{"login":"stranger"},"createdAt":"2026-08-21T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}'
actual=$(council_verdict_any_for "$two_accounts_json" "council-bot")
assert_equals "$actual" $'aaaaaaa\t2026-08-20T10:00:00Z\tcouncil-bot\t0' \
	"the named account's older verdict beats a newer one from elsewhere"
actual=$(council_verdict_any_for "$two_accounts_json" "nobody")
assert_equals "$actual" "" \
	"a login that posted nothing yields no verdict"
actual=$(council_verdict_any_for "$two_accounts_json" "all")
assert_equals "$actual" $'bbbbbbb\t2026-08-21T10:00:00Z\tstranger\t0' \
	"and scope all takes the newest of the two"

echo ""
echo "Test: a collapsed foreign verdict does not count under scope all"
# Widening the authorship gate must not widen either of the other two.
collapsed_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":true,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_any_for "$collapsed_foreign_json" "all")
assert_equals "$actual" "" \
	"collapsing a foreign verdict still forces a fresh review"

echo ""
echo "Test: a quoted foreign marker does not count under scope all"
# "Quote reply" copies the marker verbatim behind a "> " prefix, which is what
# makes column 0 the difference between a verdict and a mention of one.
quoted_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"> <!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_any_for "$quoted_foreign_json" "all")
assert_equals "$actual" "" \
	"a quote of a foreign marker is not a foreign verdict"
# And a quote must not shadow the real verdict below it. This is the assertion
# that actually pins the column-0 gate: a reader selecting on "the body
# contains the marker" would pick the newer quoting comment, find no marker
# line in it to parse, and return nothing — the same empty answer the case
# above expects, which is why that case on its own cannot tell the two readers
# apart. It was mutation-tested and did not.
quote_shadow_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"},
 {"author":{"login":"quoter"},"createdAt":"2026-08-21T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"> <!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}'
actual=$(council_verdict_any_for "$quote_shadow_json" "all")
assert_equals "$actual" $'aaaaaaa\t2026-08-20T10:00:00Z\tcouncil-bot\t0' \
	"a quoted marker does not shadow the genuine verdict beneath it"

echo ""
echo "Test: council_verdict_word reads another account's verdict under scope all"
# The row the reader is most curious about is the one whose state rests on
# somebody else's review. Refusing to read the verdict word out of the very
# comment the state was derived from is what made that row show "up-to-date*"
# beside an em dash.
word_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$word_foreign_json" "all")
assert_equals "$actual" "APPROVE" \
	"scope all reads the word out of a foreign verdict"

echo ""
echo "Test: the default scope is unchanged from the gated reading"
# The safety argument is the default, exactly as it is for classify_prs: a
# caller that passes nothing gets what this function did before it had a scope.
actual=$(council_verdict_word "$word_foreign_json")
assert_equals "$actual" "" \
	"no scope argument still means ours only"
actual=$(council_verdict_word "$word_foreign_json" "self")
assert_equals "$actual" "" \
	"and an explicit self reads the same way"
actual=$(council_verdict_word "$single_json" "self")
assert_equals "$actual" "APPROVE" \
	"while our own verdict is read under self as it always was"

echo ""
echo "Test: a named login's verdict word ignores another account's"
word_two_accounts_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"},
 {"author":{"login":"stranger"},"createdAt":"2026-08-21T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🔴 Review Council: REQUEST CHANGES\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$word_two_accounts_json" "council-bot")
assert_equals "$actual" "APPROVE" \
	"the named account's word wins over a newer one from elsewhere"
actual=$(council_verdict_word "$word_two_accounts_json" "stranger")
assert_equals "$actual" "REQUEST CHANGES" \
	"and asking about the other account gets the other answer"

echo ""
echo "Test: a foreign SPLIT verdict is read from part 1 under scope all"
# Where the two features meet: only part 1 carries the heading, and the newest
# comment of a chained verdict is its last part. Widening the authorship gate
# must not cost the part=1 preference.
word_split_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🔴 Review Council: REQUEST CHANGES\n\nfindings\n\n<!-- review-council:marker sha=abc1234 part=1 of=3 -->"},
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:01Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"more findings\n\n<!-- review-council:marker sha=abc1234 part=2 of=3 -->"},
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:02Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"last findings\n\n<!-- review-council:marker sha=abc1234 part=3 of=3 -->"}
]}'
actual=$(council_verdict_word "$word_split_foreign_json" "all")
assert_equals "$actual" "REQUEST CHANGES" \
	"part 1 carries the verdict of a foreign chained review too"

echo ""
echo "Test: a minimised foreign verdict yields no word under scope all"
word_collapsed_foreign_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":true,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=abc1234 part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$word_collapsed_foreign_json" "all")
assert_equals "$actual" "" \
	"collapsing a foreign verdict hides its word as it hides the verdict"

echo ""
echo "Test: a quoted foreign marker does not shadow the verdict word beneath it"
# Asserted against a genuine older verdict rather than against an empty
# timeline: a reader that selected on "the body contains the marker" would pick
# the newer quoting comment, find no heading in it, and return empty — the same
# answer a quote-only fixture expects, which is how such a case passes while
# testing nothing.
word_quote_shadow_json='{"comments":[
 {"author":{"login":"council-bot"},"createdAt":"2026-08-20T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"},
 {"author":{"login":"quoter"},"createdAt":"2026-08-21T10:00:00Z",
  "isMinimized":false,"viewerDidAuthor":false,
  "body":"> <!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}'
actual=$(council_verdict_word "$word_quote_shadow_json" "all")
assert_equals "$actual" "APPROVE" \
	"the quote is not a candidate, so the real verdict below it still reads"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
