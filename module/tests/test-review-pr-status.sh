#!/usr/bin/env bash
# Guards scripts/review-pr-status.sh — the read-only companion to the batch
# driver.
#
# Two things are under test here. The first is that the report agrees with the
# driver: both scripts classify through the same classify_prs, so every state
# this suite pins is the state the driver would act on. The second is that the
# script stays read-only. The mock gh below refuses `pr comment` outright
# rather than recording it, so an accidental write fails at the call site
# instead of surfacing as a missing assertion three tests later.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../scripts/review-pr-status.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SCRIPT" ]] || {
	echo "ERROR: status script not found: $SCRIPT" >&2
	exit 1
}

# Which agent CLIs the next run_case should find on PATH. Both, always: this
# script must never invoke either, and a stub that records its argv is how that
# claim is checked rather than assumed.
STUB_CLIS="claude opencode"

# Build a temp bin dir whose gh answers every query the status script makes
# offline. Two open PRs, neither previously reviewed, so a bare run always has
# something to report.
make_mockbin() {
	local dir="$1" log="$2" cli
	mkdir -p "$dir"
	cat >"$dir/gh" <<'MOCKGH'
#!/usr/bin/env bash
args="$*"
case "$args" in
auth\ status*) exit "${STUB_GH_AUTH_FAILS:-0}" ;;
*--json\ nameWithOwner*) echo "acme/widgets" ;;
# A forge outage that leaves `auth status` answering: a typo'd --repo, a 502
# or a secondary rate limit all land here. The report must tell these apart
# from a repository that simply has no open PRs.
pr\ list*)
	[[ "${STUB_GH_LIST_FAILS:-0}" -eq 0 ]] || {
		echo "gh: Could not resolve to a Repository." >&2
		exit 1
	}
	printf '2\tbbbbbbb\n1\taaaaaaa\n'
	;;
# Single-PR target: `gh pr view <n> ... --json number,headRefOid`. Every PR
# exists unless a test names one that does not, which real gh answers by
# failing rather than by printing an empty record.
*--json\ number,headRefOid*)
	[[ "$3" != "${STUB_GH_MISSING_PR:-}" ]] || {
		echo "gh: Could not resolve to a PullRequest with the number of $3." >&2
		exit 1
	}
	printf '%s\tccccccc\n' "$3"
	;;
# Comment timeline, as gh returns it: raw JSON, no --jq. The script runs its own
# jq over the payload, so these tests exercise the real program rather than a
# re-implementation of it here — which is the point, since the anchoring that
# tells a verdict from a forgery lives in that program. A PR with no fixture has
# no comments, the "never reviewed" case.
*--json\ comments*)
	if [[ -n "${MOCK_COMMENTS_DIR:-}" ]] && [[ -f "${MOCK_COMMENTS_DIR}/pr-$3.json" ]]; then
		cat "${MOCK_COMMENTS_DIR}/pr-$3.json"
	else
		echo '{"comments":[]}'
	fi
	;;
# Collaborator permission, already reduced by --jq to the bare value. Silent
# unless the test declared one, so an undeclared login reads as a lookup that
# answered nothing — the path that must fail closed.
*api\ repos/*/collaborators/*/permission*)
	if [[ -n "${MOCK_PERMS_FILE:-}" ]] && [[ -f "${MOCK_PERMS_FILE}" ]]; then
		who="${args#*collaborators/}"
		who="${who%%/permission*}"
		awk -F'\t' -v want="$who" '$1 == want { print $2 }' "${MOCK_PERMS_FILE}"
	fi
	;;
# The status script is read-only. A write is not something to record and assert
# on afterwards — it is a defect, and the mock refuses it outright so the
# failure lands at the call rather than in a later assertion.
pr\ comment*)
	echo "FATAL: review-pr-status.sh attempted a write: $args" >&2
	exit 97
	;;
# Commit authorship, already reduced by --jq to one email per line. Silence
# unless the test declared some via MOCK_EMAILS, so the default is the
# lookup-returned-nothing case, which must fail open to reporting the PR.
*--json\ commits*)
	if [[ -n "${MOCK_EMAILS_FILE:-}" ]] && [[ -f "${MOCK_EMAILS_FILE}" ]]; then
		awk -F'\t' -v pr="$3" '$1 == pr { print $2 }' "$MOCK_EMAILS_FILE"
	fi
	;;
*--json\ changedFiles,author,files*)
	echo '{"changedFiles":1,"author":{"is_bot":false},"files":[{"path":"README.md"}]}'
	;;
*) exit 1 ;;
esac
MOCKGH
	chmod +x "$dir/gh"
	for cli in $STUB_CLIS; do
		cat >"$dir/$cli" <<MOCKCLI
#!/usr/bin/env bash
echo "${cli} \$*" >>"$log"
exit 0
MOCKCLI
		chmod +x "$dir/$cli"
	done
}

# Print a PATH with the real claude and opencode removed, so the "no agent CLI
# was invoked" assertion cannot be satisfied by a developer's own install being
# called instead of the stub.
mask_agent_clis() {
	local work="$1" saved="$PATH" masked
	masked=$(path_without_command claude "$work")
	PATH="$masked"
	masked=$(path_without_command opencode "$work")
	PATH="$saved"
	printf '%s' "$masked"
}

# run_case <stdin: __eof__ | text> <script args...>
# Sets OUT (stdout+stderr), RC (exit status) and CALLS (agent CLI invocations,
# which must always be zero). Honours STUB_CLIS and any RUN_ENV entries. Runs
# inside its own temp CWD so no test depends on the developer's checkout.
run_case() {
	local input="$1"
	shift
	local work bin log masked
	work=$(mktemp -d)
	bin="$work/bin"
	log="$work/cli.log"
	make_mockbin "$bin" "$log"
	masked=$(mask_agent_clis "$work")

	# Commit authorship for the mock gh, as "<pr><TAB><email>" lines. Written
	# even when empty so the mock's -f test is the only thing distinguishing
	# "no emails declared" from "this PR has none".
	local emails_file="$work/emails.tsv"
	printf '%s' "$MOCK_EMAILS" >"$emails_file"

	# Comment timelines and collaborator permissions the mock gh will serve,
	# staged per case so one test's fixtures cannot leak into the next.
	local comments_dir="$work/comments"
	mkdir -p "$comments_dir"
	if [[ -n "$MOCK_COMMENTS" ]]; then
		cp "$MOCK_COMMENTS"/* "$comments_dir/" 2>/dev/null || true
	fi
	local perms_file="$work/perms.tsv"
	printf '%s' "$MOCK_PERMS" >"$perms_file"

	set +e
	if [[ "$input" == "__eof__" ]]; then
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" MOCK_EMAILS_FILE="$emails_file" MOCK_COMMENTS_DIR="$comments_dir" MOCK_PERMS_FILE="$perms_file" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" </dev/null 2>&1)
	else
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" MOCK_EMAILS_FILE="$emails_file" MOCK_COMMENTS_DIR="$comments_dir" MOCK_PERMS_FILE="$perms_file" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" <<<"$input" 2>&1)
	fi
	RC=$?
	set -e

	CALLS=0
	if [[ -f "$log" ]]; then
		CALLS=$(grep -c . "$log" || true)
	fi
	rm -rf "$work"
}

# Environment assignments prepended to the next run_case, as KEY=VALUE words.
RUN_ENV=()

# Commit authorship the next run_case's mock gh will report, as "<pr><TAB><email>"
# lines. Empty by default: a PR whose authorship cannot be determined is still
# reported, so every test that does not set this exercises the unfiltered path.
MOCK_EMAILS=""

# Directory of `pr-<n>.json` comment timelines the next run_case's mock gh will
# serve. Empty by default: a PR with no council comment has never been reviewed.
MOCK_COMMENTS=""

# Collaborator permissions the next run_case's mock gh will report, as
# "<login><TAB><permission>" lines. Empty by default, so an unlisted requester
# gets the lookup-answered-nothing path — which must fail closed.
MOCK_PERMS=""

# write_comments <pr> <<'JSON' ... JSON
# Stage one PR's comment timeline for the next run_case. Each test writes its
# own timeline inline rather than carrying a fixtures tree, because the shape
# under test IS the fixture: which line the marker sits on, who authored it,
# whether it is collapsed.
write_comments() {
	local pr="$1"
	[[ -n "$MOCK_COMMENTS" ]] || MOCK_COMMENTS=$(mktemp -d)
	cat >"$MOCK_COMMENTS/pr-${pr}.json"
}

# Drop staged timelines and permissions. Call between cases: a leftover verdict
# silently turns the next test's "unreviewed" PR into an up-to-date one.
reset_comments() {
	[[ -z "$MOCK_COMMENTS" ]] || rm -rf "$MOCK_COMMENTS"
	MOCK_COMMENTS=""
	MOCK_PERMS=""
}

# assert_state <pr> <expected> <label>
# Assert the STATE column of <pr>'s row in the report the last run_case
# produced.
#
# Read out of the table rather than asserted as a substring of the whole
# report, because the summary line above the table names every state word: an
# `assert_contains "$OUT" "ignored"` passes against a report where nothing is
# ignored at all, and so cannot fail when the classification is wrong.
#
# The awk runs here rather than at the call site for the same reason as
# helpers.sh's assert_jq: a command substitution nested inside another command
# has its exit status discarded, so a failing read would silently assert
# against the empty string instead of aborting the suite.
assert_state() {
	local actual
	actual=$(awk -v want="#$1" '$1 == want { print $2 }' <<<"$OUT")
	assert_equals "$actual" "$2" "$3"
}

# assert_by <pr> <expected> <label>
# Assert the BY column of <pr>'s row — the account whose verdict was counted.
#
# Field 4 of the row, which is BY only while the VERDICT cell holds a single
# word; every fixture that reaches here posts APPROVE for that reason. Read
# from the table rather than from the whole report so that a login named only
# in the foreign-marker list beneath it cannot satisfy the assertion.
assert_by() {
	local actual
	actual=$(awk -v want="#$1" '$1 == want { print $4 }' <<<"$OUT")
	assert_equals "$actual" "$2" "$3"
}

# assert_verdict <pr> <expected> <label>
# Assert the VERDICT column of <pr>'s row. Field 3, which is the verdict only
# while that cell holds a single word or an em dash — the shape every fixture
# reaching here posts, for the same reason assert_by reads field 4.
assert_verdict() {
	local actual
	actual=$(awk -v want="#$1" '$1 == want { print $3 }' <<<"$OUT")
	assert_equals "$actual" "$2" "$3"
}

# assert_tsv_field <pr> <n> <expected> <label>
# Assert field <n> of <pr>'s line in the --tsv output the last run_case
# produced, splitting on the tab that format is named for.
#
# Splitting on tabs rather than on whitespace is the whole point: a field that
# is empty holds its place, and a value containing a space stays one field. The
# awk runs here rather than at the call site because a command substitution
# nested inside another has its exit status discarded, so a failing read would
# silently assert against the empty string instead of aborting the suite.
assert_tsv_field() {
	local actual
	actual=$(awk -F'\t' -v want="$1" -v n="$2" '$1 == want { print $n }' <<<"$OUT")
	assert_equals "$actual" "$3" "$4"
}

# assert_tsv_nf <pr> <expected> <label>
# Assert how many tab-separated fields <pr>'s --tsv line carries.
#
# This is the assertion that catches a value smuggling a tab or a newline
# through: either one shifts every field after it, and NF is where that shows
# up. It also catches empty trailing fields being dropped, which is how a
# nine-field line quietly becomes an eight-field one for exactly the PRs with
# the least to report.
assert_tsv_nf() {
	local actual
	actual=$(awk -F'\t' -v want="$1" '$1 == want { print NF }' <<<"$OUT")
	assert_equals "$actual" "$2" "$3"
}

# assert_column_aligned <needle-in-header> <needle-in-row> <row-key> <label>
# Assert that a header cell and a body cell begin at the same character
# position, which is what "the table is aligned" means.
#
# Both lines have to be ASCII for this to be meaningful — an em dash is three
# bytes and one column, so a row carrying one cannot be compared by offset
# without knowing the locale. Every caller therefore picks a row with no em
# dash on it.
assert_column_aligned() {
	local header row header_col row_col
	header=$(awk '$1 == "PR" && $2 == "STATE"' <<<"$OUT")
	row=$(awk -v want="$3" '$1 == want' <<<"$OUT")
	header_col=$(awk -v s="$header" -v n="$1" 'BEGIN { print index(s, n) }')
	row_col=$(awk -v s="$row" -v n="$2" 'BEGIN { print index(s, n) }')
	if [[ "$header_col" -eq 0 ]] || [[ "$row_col" -eq 0 ]]; then
		echo "  FAIL: $4 — '$1' or '$2' is not in the table at all"
		echo "        header: $header"
		echo "        row:    $row"
		FAIL=$((FAIL + 1))
		return
	fi
	assert_equals "$row_col" "$header_col" "$4"
}

assert_contains() {
	local haystack="$1" needle="$2" label="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — output does not contain '$needle'"
		echo "        got: $haystack"
		FAIL=$((FAIL + 1))
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" label="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $label — output unexpectedly contains '$needle'"
		echo "        got: $haystack"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test: an unreviewed PR is reported as unreviewed"
run_case "__eof__" --repo acme/widgets
assert_equals "$RC" "0" "a status run exits clean"
assert_contains "$OUT" "acme/widgets" "the report names the repository"
assert_state 1 "unreviewed" "a PR with no verdict is unreviewed"
assert_equals "$CALLS" "0" "a status run invokes no agent CLI"

echo ""
echo "Test: a PR reviewed at head is up-to-date, and shows its verdict"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "up-to-date" "a PR reviewed at head is current"
assert_contains "$OUT" "APPROVE" "the verdict word is shown"
# PR 1 has no timeline in this run, so the same report carries both halves of
# the absent-value rule: a verdict that exists is printed, and one that does
# not is an em dash rather than a blank column nobody can tell from a bug.
#
# The whole row is asserted, re-joined on single spaces. Reading one column out
# by number cannot tell an em dash in the VERDICT column from an empty VERDICT
# column and the em dash in REVIEWED shifting left into its place — which is
# precisely the regression this case is here to catch.
absent_row=$(awk '$1 == "#1" { $1 = $1; print }' <<<"$OUT")
assert_equals "$absent_row" "#1 unreviewed — — — standard" \
	"every absent value on a row is an em dash"
reset_comments

echo ""
echo "Test: a long verdict is clipped rather than left to break the table"
# The verdict is whatever the council wrote, and nothing bounds its length.
# Clipping is what keeps one unusually long word from pushing the two columns
# after it out of line on that row alone.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟣 Review Council: REQUEST CHANGES WITH ADVISORIES\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_contains "$OUT" "REQUEST CHANGES W…" "a long verdict is cut to its column with an ellipsis"
assert_not_contains "$OUT" "WITH ADVISORIES" "and the overflow is not printed"
last_column=$(awk '$1 == "#2" { print $NF }' <<<"$OUT")
assert_equals "$last_column" "standard" "the columns after it still hold their values"
reset_comments

echo ""
echo "Test: a PR reviewed at an older commit is stale"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=0000001 part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "stale" "new commits since the verdict make it stale"
reset_comments

echo ""
echo "Test: a bot-authored PR is reported as ignored, not hidden"
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets
assert_state 1 "ignored" "a bot PR is visible but marked ignored"
assert_state 2 "unreviewed" "and its neighbour is unaffected"
MOCK_EMAILS=""

echo ""
echo "Test: naming an ignored PR explicitly reports it on its own terms"
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets 1
assert_state 1 "unreviewed" "an explicit target bypasses the ignore list"
MOCK_EMAILS=""

echo ""
echo "Test: an authorised request at head is reported as requested"
reset_comments
MOCK_PERMS=$'maint\twrite'
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"},
 {"author":{"login":"maint"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-21T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"/review-council review"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "requested" "an authorised request is reported"
reset_comments

echo ""
echo "Test: an unreadable permission answer leaves the PR out of requested"
# The one fail-closed lookup. MOCK_PERMS is empty, so the mock answers nothing.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"},
 {"author":{"login":"stranger"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-21T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"/review-council review"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "up-to-date" "an unreadable permission is not permission"
reset_comments

echo ""
echo "Test: a foreign marker is reported"
# Run under --account self, the scope that refuses a marker it did not post.
# The default scope counts that same marker on purpose — there is no telling a
# fleet's bot account from a stranger in the payload — so the case for naming
# an untrusted marker is a case about self.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"stranger"},"authorAssociation":"NONE",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --account self
assert_contains "$OUT" "stranger" "a marker from another account is named"
assert_state 2 "unreviewed" "and the PR is still reported as unreviewed"
reset_comments

echo ""
echo "Test: a failed PR listing is fatal, not an empty report"
# collect_prs runs inside `prs_raw="$(collect_prs)"`, and bash unsets errexit
# inside a command-substitution subshell unless `shopt -s inherit_errexit` is
# set — which nothing in this tree sets. So a failing `gh pr list` aborts
# nothing, and a caller that only tests for empty output would announce a
# broken lookup as "no open pull requests" and exit 0.
RUN_ENV=(STUB_GH_LIST_FAILS=1)
run_case "__eof__" --repo acme/widgets
RUN_ENV=()
assert_equals "$RC" "1" "a broken listing exits non-zero"
assert_not_contains "$OUT" "No open pull requests found" \
	"and never claims the repository has nothing to report"
assert_contains "$OUT" "Could not list the open pull requests" \
	"the operator is told the lookup failed"

echo ""
echo "Test: a named PR that does not exist reports only its own message"
RUN_ENV=(STUB_GH_MISSING_PR=999999)
run_case "__eof__" --repo acme/widgets 999999
RUN_ENV=()
assert_equals "$RC" "1" "a missing PR exits 1"
assert_contains "$OUT" "PR #999999 not found in acme/widgets." "it says which PR"
assert_not_contains "$OUT" "ERROR: " \
	"a handled error is not decorated with an internal one"

echo ""
echo "Test: the status script works through a symlink"
# The lib lookup must follow the link to the real script's directory. A
# `dirname "$0"` resolver looks beside the LINK and finds no lib/ at all.
link_dir=$(mktemp -d)
ln -s "$SCRIPT" "$link_dir/rc-status"
SAVED_SCRIPT="$SCRIPT"
SCRIPT="$link_dir/rc-status"
run_case "__eof__" --repo acme/widgets
assert_equals "$RC" "0" "a symlinked status script runs"
assert_state 1 "unreviewed" "and classifies normally"

echo ""
echo "Test: --help works through a symlink"
# usage() reads SCRIPT_REAL, not $0: through a link, `sed` over the link path
# would print the target's bytes only by accident of the reader following it,
# and prints nothing at all for a relative link resolved from another CWD.
run_case "__eof__" --help
assert_equals "$RC" "0" "--help through a symlink exits clean"
assert_contains "$OUT" "review-pr-status.sh" "and still prints the real header"
SCRIPT="$SAVED_SCRIPT"
rm -rf "$link_dir"

echo ""
echo "Test: the status script works through a two-hop relative symlink"
# Each hop must re-base against the directory of the link it came from. A
# resolver that only canonicalises once mis-resolves the relative second hop.
hop_root=$(mktemp -d)
mkdir -p "$hop_root/a" "$hop_root/b"
ln -s "$SCRIPT" "$hop_root/a/first"
ln -s "../a/first" "$hop_root/b/second"
SAVED_SCRIPT="$SCRIPT"
SCRIPT="$hop_root/b/second"
run_case "__eof__" --repo acme/widgets
assert_equals "$RC" "0" "a two-hop relative symlink resolves"
assert_state 1 "unreviewed" "and classifies normally"
SCRIPT="$SAVED_SCRIPT"
rm -rf "$hop_root"

echo ""
echo "Test: --help prints the header"
run_case "__eof__" --help
assert_equals "$RC" "0" "--help exits clean"
assert_contains "$OUT" "review-pr-status.sh" "the header names the script"
assert_not_contains "$OUT" "shellcheck disable" \
	"and stops before the lint waiver below it"

echo ""
echo "Test: an unknown option is a usage error"
run_case "__eof__" --repo acme/widgets --nonsense
assert_equals "$RC" "2" "an unknown option exits 2"
assert_contains "$OUT" "Unknown option: --nonsense" "and names the option"

echo ""
echo "Test: a second positional target is refused"
run_case "__eof__" --repo acme/widgets 1 2
assert_equals "$RC" "2" "two targets exit 2"
assert_contains "$OUT" "Only one PR target" "and say why"

echo ""
echo "Test: a bad DEEP_FILES is refused before anything is read"
# common.sh validates at source time, so the failure lands before the first gh
# call rather than as a silently wrong effort tier mid-report.
RUN_ENV=(DEEP_FILES=lots)
run_case "__eof__" --repo acme/widgets
RUN_ENV=()
assert_equals "$RC" "2" "a non-numeric threshold exits 2"
assert_contains "$OUT" "DEEP_FILES must be a non-negative integer" "and names it"

echo ""
echo "Test: --no-ignore-emails reports a bot PR on its own terms"
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets --no-ignore-emails
assert_state 1 "unreviewed" "clearing the list un-ignores the PR"
MOCK_EMAILS=""

echo ""
echo "Test: --ignore-email adds an address to the list"
MOCK_EMAILS=$'1\tci@corp.example'
run_case "__eof__" --repo acme/widgets --ignore-email ci@corp.example
assert_state 1 "ignored" "an added address is honoured"
MOCK_EMAILS=""

echo ""
echo "Test: the forecast column is headed WOULD RUN"
# The heading sat beside REVIEWED and read past-tense, so a row saying
# "unreviewed ... deep" invited "how does it know it is deep if nobody ran it?".
# effort_for forecasts from the PR's current metadata; the heading now says so.
run_case "__eof__" --repo acme/widgets
assert_contains "$OUT" "WOULD RUN" "the depth forecast is headed as a forecast"
assert_not_contains "$OUT" "EFFORT" "and the past-tense heading is gone"

echo ""
echo "Test: the report names the account scope it answered under"
# A report that counts other accounts' verdicts is answering a different
# question from one that counts only this account's, and has to say which.
run_case "__eof__" --repo acme/widgets
assert_contains "$OUT" "(accounts: all)" "the default scope is the fleet view"

echo ""
echo "Test: another account's verdict counts under the default scope"
# The council posting from a bot account, or from a second machine: every
# verdict it left has viewerDidAuthor false. Reporting all of those as
# unreviewed is what this scope exists to fix.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "up-to-date*" "a foreign verdict at head reads as current, starred"
assert_by 2 "council-bot" "and the account that posted it is named"
# The state rests on this comment, so the verdict word comes out of it too. A
# row reading "up-to-date* —" says "reviewed, verdict unknown", which reads as
# a defect to whoever sees it.
assert_verdict 2 "APPROVE" "and the word is read from the same comment"
assert_contains "$OUT" "* reviewed by another account" \
	"the star is explained beneath the table"
# The same comment described twice, once as counted and once as suspicious, is
# a report contradicting itself in the space of ten lines.
assert_not_contains "$OUT" "Council marker from another account" \
	"a counted verdict is not also listed as a foreign marker"

echo ""
echo "Test: --account self is the driver's own view of the same PR"
run_case "__eof__" --repo acme/widgets --account self
assert_contains "$OUT" "(accounts: self)" "the narrowed scope is named"
assert_state 2 "unreviewed" "a verdict from another account does not count under self"
assert_verdict 2 "—" "and its word is not read either, as before"
assert_contains "$OUT" "Council marker from another account" \
	"and the marker it refused is reported as foreign"
assert_not_contains "$OUT" "DID count is named in the BY" \
	"with no note about counted markers, which this scope has none of"
reset_comments

echo ""
echo "Test: a counted account's unparseable marker leaves no reviewer behind"
# A marker whose sha is not a sha is not a verdict, under any scope. The PR
# reports as unreviewed, and the row must not still name the account that
# posted the thing that was rejected — a reviewer beside "unreviewed" reads as
# a report contradicting itself.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=not-a-sha part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_state 2 "unreviewed" "an unparseable sha is not a verdict under scope all either"
assert_by 2 "—" "and no account is credited with it"
assert_contains "$OUT" "Council marker from another account" \
	"the marker that was not counted is reported as foreign"
assert_contains "$OUT" "DID count is named in the BY" \
	"and the list says that a counted marker would not have been listed"
reset_comments

echo ""
echo "Test: --account <login> counts that login and no other"
# Two markers, the newer from an account that is not the one asked about. The
# scope has to pick the named account's older verdict, not simply the newest.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"},
 {"author":{"login":"stranger"},"authorAssociation":"NONE",
  "createdAt":"2026-08-21T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=0000001 part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --account council-bot
assert_state 2 "up-to-date*" "the named account's verdict is at head"
assert_by 2 "council-bot" "and it is the one reported"
assert_not_contains "$OUT" "Council marker from another account" \
	"the newer marker from elsewhere is neither counted nor double-reported"
run_case "__eof__" --repo acme/widgets --account stranger
assert_state 2 "stale*" "asking about the other account gets that account's answer"
assert_by 2 "stranger" "named as the account whose verdict was read"
# stranger's marker carries no heading, and the scope keeps council-bot's out
# of reach: the word column follows the scope rather than the other way round.
assert_verdict 2 "—" "and no word, because that account's comment has none"
reset_comments

echo ""
echo "Test: --account requires a login"
run_case "__eof__" --repo acme/widgets --account
assert_equals "$RC" "2" "a bare --account exits 2"
assert_contains "$OUT" "--account requires an argument" "and says what it wanted"

echo ""
echo "Test: --account '' is refused rather than matching nobody"
# An empty scope is not a narrow scope: no author.login equals it, so every
# reviewed PR would report as unreviewed and the whole repository would read as
# untouched. That is the one wrong answer available here, so it is refused.
run_case "__eof__" --repo acme/widgets --account ""
assert_equals "$RC" "2" "an empty --account exits 2"
assert_contains "$OUT" "--account requires a non-empty login" "and says why"

echo ""
echo "Test: the ERR trap is installed before comments.sh is sourced"
# Regression guard for a silent-failure window, not a style preference. If the
# trap were armed only after comments.sh is sourced, a source-time failure in
# comments.sh (a typo, an unbound variable, a bad regex) would exit non-zero
# with no ERROR message at all — this is the script's entire failure-reporting
# story for the sourcing step, and it only works installed first.
#
# `|| true` on each lookup so that a line which has gone missing entirely
# reaches the "could not locate" branch below and is reported. Without it the
# failing grep takes the pipeline down under `set -o pipefail` and the suite
# aborts at this point with no message, which is the one outcome a regression
# guard must not have.
# shellcheck disable=SC2016 # literal source text being grepped for, not command substitution.
trap_line=$(grep -nF 'trap "$ERR_TRAP" ERR' "$SCRIPT" | head -1 | cut -d: -f1) || true
# shellcheck disable=SC2016 # literal source text being grepped for, not command substitution.
comments_source_line=$(grep -nF 'source "$LIB_DIR/comments.sh"' "$SCRIPT" | head -1 | cut -d: -f1) || true
if [[ -z "$trap_line" || -z "$comments_source_line" ]]; then
	echo "  FAIL: could not locate the ERR trap install or the comments.sh source line in $SCRIPT"
	FAIL=$((FAIL + 1))
elif [[ "$trap_line" -lt "$comments_source_line" ]]; then
	echo "  PASS: ERR trap (line $trap_line) is armed before comments.sh is sourced (line $comments_source_line)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: ERR trap (line $trap_line) is armed at or after comments.sh is sourced (line $comments_source_line)"
	echo "        a source-time failure in comments.sh would then exit with no ERROR message at all"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Test: the ERR trap is installed before prs.sh is sourced"
# Same guard, extended to prs.sh: it is sourced after comments.sh (it depends on
# comments.sh's marker readers), but the trap still has to be armed before it.
# shellcheck disable=SC2016 # literal source text being grepped for, not command substitution.
prs_source_line=$(grep -nF 'source "$LIB_DIR/prs.sh"' "$SCRIPT" | head -1 | cut -d: -f1) || true
if [[ -z "$trap_line" || -z "$prs_source_line" ]]; then
	echo "  FAIL: could not locate the ERR trap install or the prs.sh source line in $SCRIPT"
	FAIL=$((FAIL + 1))
elif [[ "$trap_line" -lt "$prs_source_line" ]]; then
	echo "  PASS: ERR trap (line $trap_line) is armed before prs.sh is sourced (line $prs_source_line)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: ERR trap (line $trap_line) is armed at or after prs.sh is sourced (line $prs_source_line)"
	echo "        a source-time failure in prs.sh would then exit with no ERROR message at all"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Test: --json emits a parseable envelope with the full field set"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --json
assert_equals "$RC" "0" "--json exits clean"
jq_rc=0
printf '%s' "$OUT" | jq empty >/dev/null 2>&1 || jq_rc=$?
assert_equals "$jq_rc" "0" "jq parses the whole document with no leading or trailing noise"
assert_jq_str "$OUT" '.repo' "acme/widgets" "the envelope names the repository"
assert_jq_str "$OUT" '.account_scope' "all" "and the default account scope"
assert_jq_str "$OUT" '.pull_requests | length' "2" "every PR appears"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .number | type' "number" \
	"the PR number is a JSON number, not a string"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .verdict' "APPROVE" \
	"a reviewed PR carries its verdict"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 1) | .verdict' "null" \
	"an unreviewed PR carries null, not an em dash"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .reviewed_is_ours' "true" \
	"our own verdict is reviewed_is_ours: true, a real boolean"
reset_comments

echo ""
echo "Test: --json carries reviewed_by/reviewed_is_ours without any table decoration"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --json
assert_equals "$RC" "0" "--json exits clean for a foreign-but-counted verdict"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .state' "up-to-date" \
	"state carries no asterisk in JSON, even though the table would star this row"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .reviewed_by' "council-bot" \
	"reviewed_by names the account that posted the counted verdict"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .reviewed_is_ours' "false" \
	"reviewed_is_ours is a boolean false for a foreign verdict"
# The verdict word must be read under the same VERDICT_SCOPE the state was
# decided under — a hardcoded "self" here would silently gate it back to
# viewerDidAuthor and lose the word for exactly the accounts this scope exists
# to admit, while every other assertion in this case kept passing.
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .verdict' "APPROVE" \
	"the verdict word is read under the same scope as the state, not hardcoded to self"
assert_not_contains "$OUT" "*" "no asterisk decoration anywhere in the JSON output"
assert_not_contains "$OUT" "review-council status" "no human summary line"
assert_not_contains "$OUT" "Requested re-reviews" "no ledger line"
assert_not_contains "$OUT" "reviewed by another account" "no footnote text"
reset_comments

echo ""
echo "Test: account_scope reflects the resolved --account value"
run_case "__eof__" --repo acme/widgets --json
assert_jq_str "$OUT" '.account_scope' "all" "the default is the fleet view"
run_case "__eof__" --repo acme/widgets --json --account self
assert_jq_str "$OUT" '.account_scope' "self" "self is reported verbatim"
run_case "__eof__" --repo acme/widgets --json --account council-bot
assert_jq_str "$OUT" '.account_scope' "council-bot" "a named login is reported verbatim"

echo ""
echo "Test: a login containing a quote does not break the document, and round-trips"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"str\"anger"},"authorAssociation":"NONE",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --json
assert_equals "$RC" "0" "a quoted login still yields valid JSON, exit 0"
assert_jq_str "$OUT" '.pull_requests | length' "2" "and the document still parses"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .reviewed_by' 'str"anger' \
	"the login round-trips through reviewed_by exactly, quote included"
run_case "__eof__" --repo acme/widgets --json --account self
assert_equals "$RC" "0" "still valid JSON when the same marker is refused as foreign"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .state' "unreviewed" \
	"self refuses the foreign marker"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .foreign_marker' 'str"anger' \
	"and the login round-trips through foreign_marker just as exactly"
reset_comments

echo ""
echo "Test: under --account self a foreign-reviewed PR is unreviewed, matching the table"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --account self
assert_state 2 "unreviewed" "the table refuses a foreign verdict under self"
run_case "__eof__" --repo acme/widgets --account self --json
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .state' "unreviewed" \
	"the JSON agrees with the table"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 2) | .verdict' "null" \
	"and carries no verdict, not an em dash"
reset_comments

echo ""
echo "Test: an ignored PR's effort is null in JSON, mirroring the table's em dash"
# The table skips effort_for entirely for an ignored PR — it would not be
# reviewed at all — and the JSON branch has to make the same call rather than
# reporting a forecast for a review that will never run.
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets --json
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 1) | .state' "ignored" "the ignored PR is reported, not hidden"
assert_jq_str "$OUT" '.pull_requests[] | select(.number == 1) | .effort' "null" "and its effort is null, not a forecast"
MOCK_EMAILS=""

echo ""
echo "Test: JSON state values agree with the table's state values for the same fixture"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
table_pr1_state=$(awk '$1 == "#1" { print $2 }' <<<"$OUT")
table_pr2_state=$(awk '$1 == "#2" { print $2 }' <<<"$OUT")
run_case "__eof__" --repo acme/widgets --json
json_pr1_state=$(printf '%s' "$OUT" | jq -r '.pull_requests[] | select(.number == 1) | .state')
json_pr2_state=$(printf '%s' "$OUT" | jq -r '.pull_requests[] | select(.number == 2) | .state')
assert_equals "$json_pr1_state" "$table_pr1_state" "PR1 state agrees between the two renderings"
assert_equals "$json_pr2_state" "$table_pr2_state" "PR2 state agrees between the two renderings"
reset_comments

echo ""
echo "Test: --exit-code yields 10 when a PR needs review"
run_case "__eof__" --repo acme/widgets --exit-code
assert_equals "$RC" "10" "pending work exits 10"

echo ""
echo "Test: without --exit-code the same pending PR still exits 0"
# A backlog is not a failure unless the flag was asked for.
run_case "__eof__" --repo acme/widgets
assert_equals "$RC" "0" "a backlog alone is not a failure"

echo ""
echo "Test: --exit-code yields 0 when every PR is up-to-date"
reset_comments
write_comments 1 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"}
]}
JSON
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --exit-code
assert_equals "$RC" "0" "a fully reviewed repository exits 0"
reset_comments

echo ""
echo "Test: --exit-code yields 0 when the only open PRs are ignored"
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com\n2\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets --exit-code
assert_equals "$RC" "0" "bot PRs alone are not a backlog"
MOCK_EMAILS=""

echo ""
echo "Test: --exit-code distinguishes a backlog from an outage"
# The entire reason 10 is not 1. An unauthenticated gh must not look like
# "three PRs are waiting" to a cron wrapper.
RUN_ENV=(STUB_GH_AUTH_FAILS=1)
run_case "__eof__" --repo acme/widgets --exit-code
RUN_ENV=()
assert_equals "$RC" "1" "an unauthenticated gh exits 1, not 10"

echo ""
echo "Test: --exit-code with a failing PR listing is still a hard failure"
# gh auth succeeds here; only the listing fails. Must not become 10 (a
# backlog) or 0 (nothing to report) — it is neither.
RUN_ENV=(STUB_GH_LIST_FAILS=1)
run_case "__eof__" --repo acme/widgets --exit-code
RUN_ENV=()
assert_equals "$RC" "1" "a broken listing exits 1, not 10"
assert_not_contains "$OUT" "No open pull requests found" \
	"and never claims the repository has nothing to report"

echo ""
echo "Test: --exit-code --json yields the same code as the table for the same fixture"
run_case "__eof__" --repo acme/widgets --exit-code
table_rc="$RC"
run_case "__eof__" --repo acme/widgets --exit-code --json
assert_equals "$RC" "$table_rc" "the exit status is about the classification, not the presentation"

echo ""
echo "Test: a foreign-reviewed PR exits 0 under the default scope, 10 under --account self"
# Same fact as the table's * marker and the JSON's reviewed_is_ours: whether
# the counted verdict is trusted depends on the scope in force.
reset_comments
write_comments 1 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"}
]}
JSON
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --exit-code
assert_equals "$RC" "0" "the fleet scope counts the foreign verdict, so nothing is pending"
run_case "__eof__" --repo acme/widgets --exit-code --account self
assert_equals "$RC" "10" "self refuses that verdict, so the PR is pending"
reset_comments

echo ""
echo "Test: the BY column widens to fit the longest account rather than clipping it"
# A truncated login is not merely ugly: the reader cannot paste it back into
# --account. `dependabot[bot]` is 15 characters against a column that used to be
# a fixed 14, so it is the shortest real account name that exposed the bug.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"dependabot[bot]"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets
assert_by 2 "dependabot[bot]" "the account name is printed in full"
assert_not_contains "$OUT" "…" "and nothing on the table was clipped"
# The row is ASCII throughout — no em dash reaches it — so a byte offset is a
# character offset here and the two lines can be compared directly.
assert_column_aligned "WOULD RUN" "standard" "#2" \
	"the columns after BY start where their headings do"
reset_comments

echo ""
echo "Test: an all-empty BY column keeps its heading rather than collapsing"
# Under --account self nothing is ever named in BY, so the widest value present
# is the em dash. A column sized to its content alone would render a heading of
# "B" or nothing at all.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --account self
header_by=$(awk '$1 == "PR" && $2 == "STATE" { print $4 }' <<<"$OUT")
assert_equals "$header_by" "BY" "the heading survives an empty column"
assert_by 2 "—" "and the column still holds the em dash beneath it"
assert_verdict 2 "APPROVE" "with the columns either side of it unmoved"
reset_comments

echo ""
echo "Test: --tsv emits the nine documented fields, in order, for a reviewed PR"
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --tsv
assert_equals "$RC" "0" "--tsv exits clean"
assert_tsv_nf 2 "9" "a fully populated PR carries nine fields"
assert_tsv_field 2 1 "2" "field 1 is the number"
assert_tsv_field 2 2 "up-to-date" "field 2 is the state"
assert_tsv_field 2 3 "APPROVE" "field 3 is the verdict"
assert_tsv_field 2 4 "council" "field 4 is the reviewing account"
assert_tsv_field 2 5 "1" "field 5 is is_ours, 1 for our own verdict"
assert_tsv_field 2 6 "2026-08-20T10:00:00Z" "field 6 is the ISO timestamp, not a relative age"
assert_tsv_field 2 7 "standard" "field 7 is the effort forecast"
assert_tsv_field 2 8 "bbbbbbb" "field 8 is the head sha"
assert_tsv_field 2 9 "bbbbbbb" "field 9 is the reviewed sha"

echo ""
echo "Test: --tsv carries no header line and no human decoration"
# Same run as above: the whole output is the rows, which is what makes it safe
# to pipe straight into awk without a `tail -n +2` nobody remembers to write.
tsv_lines=$(grep -c . <<<"$OUT")
assert_equals "$tsv_lines" "2" "one line per PR and nothing else"
assert_not_contains "$OUT" "STATE" "no header line"
assert_not_contains "$OUT" "review-council status" "no summary line"
assert_not_contains "$OUT" "Requested re-reviews" "no ledger line"
assert_not_contains "$OUT" "—" "no em dashes"
assert_not_contains "$OUT" "*" "no asterisk"
assert_not_contains "$OUT" "reviewed by another account" "no footnote"
reset_comments

echo ""
echo "Test: an absent value in --tsv is an empty field, and the line still has nine"
# The case a naive implementation gets wrong: six of this PR's nine fields are
# empty, and dropping the trailing ones silently shifts every consumer's column
# numbers for exactly the PRs with the least to report.
run_case "__eof__" --repo acme/widgets --tsv
assert_tsv_nf 1 "9" "an unreviewed PR still carries nine fields"
assert_tsv_field 1 2 "unreviewed" "its state is reported"
assert_tsv_field 1 3 "" "the absent verdict is an empty field, not an em dash"
assert_tsv_field 1 4 "" "and so is the absent account"
assert_tsv_field 1 5 "0" "is_ours is 0, never empty"
assert_tsv_field 1 6 "" "and the absent review time"
assert_tsv_field 1 8 "aaaaaaa" "the head sha is still reported"
assert_tsv_field 1 9 "" "and the absent reviewed sha is the empty ninth field"

echo ""
echo "Test: an ignored PR's effort is empty in --tsv, as it is null in --json"
MOCK_EMAILS=$'1\tdependabot[bot]@users.noreply.github.com'
run_case "__eof__" --repo acme/widgets --tsv
assert_tsv_field 1 2 "ignored" "the ignored PR is reported, not hidden"
assert_tsv_field 1 7 "" "and carries no forecast for a review that will not run"
assert_tsv_nf 1 "9" "with its nine fields intact"
MOCK_EMAILS=""

echo ""
echo "Test: a verdict containing a tab cannot shift the fields after it"
# The live field-splitting hazard. The verdict is whatever follows
# "## <emoji> Review Council: " in a heading, and a heading is free text a
# person types — so a tab in it would move every later field one column right
# and a consumer's `cut -f5` would read the wrong value with no error anywhere.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\tWITH NOTES\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --tsv
assert_tsv_nf 2 "9" "a tab inside a value does not become a tenth field"
assert_tsv_field 2 3 "APPROVE WITH NOTES" "it is replaced by a space in place"
assert_tsv_field 2 7 "standard" "and the fields after it keep their positions"
reset_comments

echo ""
echo "Test: a multi-line verdict body still yields exactly one line per PR"
# The heading is one line of a body that has several. A renderer that emitted
# the body rather than the word — or that left a newline in a field — would
# turn one PR into several rows, and a consumer reading line-by-line would
# attribute the extra rows to nothing at all.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\nfirst finding\nsecond finding\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --tsv
tsv_lines=$(grep -c . <<<"$OUT")
assert_equals "$tsv_lines" "2" "two PRs, two lines"
assert_tsv_nf 2 "9" "and the row is still nine fields"
assert_tsv_field 2 3 "APPROVE" "carrying the heading's word alone"
reset_comments

echo ""
echo "Test: --tsv does not clip a long verdict"
# The table cuts a verdict to its column so one long value cannot break the
# alignment of every other row. That is a layout concern and has no business in
# a machine format, where a truncated value is simply a wrong one.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟣 Review Council: REQUEST CHANGES WITH ADVISORIES\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --tsv
assert_tsv_field 2 3 "REQUEST CHANGES WITH ADVISORIES" "the verdict is whole"
assert_not_contains "$OUT" "…" "and no ellipsis was emitted"
reset_comments

echo ""
echo "Test: is_ours is 0 for a counted verdict from another account"
# The machine form of the table's `*`. The default scope counts a fleet
# account's verdict, and this field is where that widening shows up per row.
reset_comments
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council-bot"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":false,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --tsv
assert_tsv_field 2 2 "up-to-date" "the state carries no asterisk in --tsv"
assert_tsv_field 2 4 "council-bot" "the account is named"
assert_tsv_field 2 5 "0" "and is_ours says the verdict is not ours"
run_case "__eof__" --repo acme/widgets --tsv --account self
assert_tsv_field 2 2 "unreviewed" "self refuses that verdict, as it does everywhere"
assert_tsv_field 2 5 "0" "with nothing of ours to claim"
reset_comments

echo ""
echo "Test: --tsv with --json is a usage error"
# They are alternative renderings of the same classification. Letting one win
# silently would hide a scripting mistake in whichever wrapper passed both.
run_case "__eof__" --repo acme/widgets --tsv --json
assert_equals "$RC" "2" "--tsv --json exits 2"
assert_contains "$OUT" "--tsv and --json" "and names both flags"
run_case "__eof__" --repo acme/widgets --json --tsv
assert_equals "$RC" "2" "the other order exits 2 as well"

echo ""
echo "Test: --exit-code means the same thing under --tsv as it does under the table"
# The exit status describes the classification, not the presentation.
run_case "__eof__" --repo acme/widgets --exit-code
tsv_table_rc="$RC"
run_case "__eof__" --repo acme/widgets --exit-code --tsv
assert_equals "$RC" "$tsv_table_rc" "a pending backlog exits the same either way"
assert_equals "$RC" "10" "which for this fixture is 10"
reset_comments
write_comments 1 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=aaaaaaa part=1 of=1 -->"}
]}
JSON
write_comments 2 <<'JSON'
{"comments":[
 {"author":{"login":"council"},"authorAssociation":"OWNER",
  "createdAt":"2026-08-20T10:00:00Z","isMinimized":false,"viewerDidAuthor":true,
  "body":"## 🟢 Review Council: APPROVE\n\n<!-- review-council:marker sha=bbbbbbb part=1 of=1 -->"}
]}
JSON
run_case "__eof__" --repo acme/widgets --exit-code --tsv
assert_equals "$RC" "0" "and a fully reviewed repository exits 0 under --tsv too"
reset_comments

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
