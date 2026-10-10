#!/usr/bin/env bash
# Per-forge PR adapters: the seam that keeps forge API shapes out of the
# preparation stages.
#
# The bug this suite was written for: `statusCheckRollup` mixes two GraphQL
# node types. Legacy commit statuses are `StatusContext` (`.context`/`.state`);
# everything GitHub Actions produces is `CheckRun` (`.name`/`.conclusion`, and
# no `.context` at all). The extractor filtered on `select(.context != null)`,
# so on any Actions-based repository it kept zero of N checks — no
# `--- STATUS CHECKS ---` section, no `ci-status.txt`, and the Quality Gates
# phase silently inert. Every fixture in the prepare suites stubbed
# `"statusCheckRollup": []`, so nothing exercised the extractor at all.
#
# shellcheck disable=SC2030,SC2031 # Each adapter call runs in a `( … )` with
# its own PATH so a fake forge CLI is visible to that case and no other. The
# modification being local to the subshell is the isolation, not a bug.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

SCRIPTS="$SCRIPT_DIR/../skills/review-council/scripts"
FORGE_DIR="$SCRIPTS/lib/forge"

# --------------------------------------------------------------------------
# Adapter unit tests: call the contract directly with a fake forge CLI.
# --------------------------------------------------------------------------

# Run rc_forge_fetch_pr from the github adapter against a canned `gh pr view`
# payload and print the resulting pr_status_checks, one `<name>: <grade>` per
# line. Isolated in a subshell so the globals the adapter sets cannot leak
# between cases.
# Usage: checks=$(github_checks_for '<statusCheckRollup json array>')
github_checks_for() {
	local rollup="$1" bindir
	# Without this the "empty rollup" case passes when the adapter is missing
	# entirely — an unset variable and a correctly empty result look the same.
	[[ -f "$FORGE_DIR/github.sh" ]] || {
		echo "ERROR: adapter not found: $FORGE_DIR/github.sh" >&2
		exit 1
	}
	bindir=$(mktemp -d)
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
"pr view")
	cat <<'JSON'
{"number":7,"title":"T","body":"B","baseRefName":"main","headRefName":"feat","url":"https://github.com/acme/widgets/pull/7","state":"OPEN","statusCheckRollup":${rollup}}
JSON
	;;
*) exit 0 ;;
esac
GH
	chmod +x "$bindir/gh"
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/github.sh
		source "$FORGE_DIR/github.sh"
		pr_title="" pr_body="" pr_base="" pr_head="" pr_url="" pr_state="" pr_status_checks=""
		rc_forge_fetch_pr 7 acme widgets
		printf '%s' "$pr_status_checks"
	)
	rm -rf "$bindir"
}

echo "Test 1: GitHub Actions check runs are normalized (the RC regression)"
actual=$(github_checks_for '[
  {"__typename":"CheckRun","name":"unit tests","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}
]')
assert_equals "$actual" 'unit tests: SUCCESS
lint: FAILURE' "CheckRun nodes yield name: conclusion"

echo "Test 2: legacy commit statuses still work"
actual=$(github_checks_for '[
  {"__typename":"StatusContext","context":"ci/jenkins","state":"SUCCESS"}
]')
assert_equals "$actual" 'ci/jenkins: SUCCESS' "StatusContext nodes yield context: state"

echo "Test 3: a rollup carrying both node types keeps both"
actual=$(github_checks_for '[
  {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},
  {"__typename":"StatusContext","context":"ci/jenkins","state":"FAILURE"}
]')
assert_equals "$actual" 'build: SUCCESS
ci/jenkins: FAILURE' "mixed rollup keeps both node types"

echo "Test 4: an in-flight check run is reported, not dropped"
# A running CheckRun has a null conclusion. Filtering those out removed them
# from the table entirely rather than rendering them pending, so a PR whose
# critical check was mid-flight read as fully green.
actual=$(github_checks_for '[
  {"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null}
]')
assert_equals "$actual" 'e2e: null' "in-flight CheckRun renders as null (graded pending downstream)"

echo "Test 5: a node naming neither field is skipped rather than emitted blank"
actual=$(github_checks_for '[
  {"__typename":"CheckRun","conclusion":"SUCCESS"},
  {"__typename":"CheckRun","name":"real","conclusion":"SUCCESS"}
]')
assert_equals "$actual" 'real: SUCCESS' "nameless node dropped, named node kept"

echo "Test 6: an empty rollup produces no checks"
actual=$(github_checks_for '[]')
assert_equals "$actual" '' "empty rollup yields empty status checks"

# --------------------------------------------------------------------------
# Seam tests: forge specifics must not leak back into the shared stages.
# --------------------------------------------------------------------------

echo "Test 7: the preparation stages hold no forge CLI invocations"
# Every `gh`/`glab` call belongs in an adapter. A stage that reaches for one
# directly is the drift this seam exists to prevent — it is exactly how the
# GitLab branch ended up a partial copy of the GitHub one.
leaks=$(grep -nE '(^|[^-[:alnum:]_])(gh|glab) [a-z]' \
	"$SCRIPTS"/lib/prepare-*.sh 2>/dev/null |
	grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
assert_equals "$leaks" "" "no gh/glab invocation outside scripts/lib/forge/"

echo "Test 8: every adapter defines the whole contract"
for adapter in "$FORGE_DIR"/*.sh; do
	name=$(basename "$adapter" .sh)
	for fn in rc_forge_fetch_pr rc_forge_fetch_diff; do
		if grep -qE "^${fn}\(\)" "$adapter"; then
			echo "  PASS: $name defines $fn"
			PASS=$((PASS + 1))
		else
			echo "  FAIL: $name does not define $fn"
			FAIL=$((FAIL + 1))
		fi
	done

	# `rc_forge_current_user` is OPTIONAL. prepare-context.sh asks `declare -F`
	# before calling and degrades to marker-only matching when the answer is no,
	# so an adapter that omits it is honoured, not failed. Ask the stage's own
	# question — source the adapter and look the function up — rather than
	# grepping, because the two answers can differ: a definition nested inside a
	# conditional, or a name that only ever appears in prose, leaves the stage on
	# the "absent" path while the file reads as though the capability ships.
	if (
		# shellcheck source=/dev/null
		source "$adapter" >/dev/null 2>&1
		declare -F rc_forge_current_user >/dev/null
	); then
		echo "  PASS: $name defines rc_forge_current_user"
		PASS=$((PASS + 1))
	elif grep -qF 'rc_forge_current_user()' "$adapter"; then
		echo "  FAIL: $name names rc_forge_current_user but sourcing defines no such function"
		FAIL=$((FAIL + 1))
	else
		echo "  PASS: $name omits rc_forge_current_user (marker-only fallback, by design)"
		PASS=$((PASS + 1))
	fi
done

# --------------------------------------------------------------------------
# End-to-end: an Actions-only PR must reach ci-status.txt with real grades.
# --------------------------------------------------------------------------

echo "Test 9: an Actions-only PR produces a graded ci-status.txt"
work=$(mktemp -d)
bindir=$(mktemp -d)
cat >"$bindir/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
"pr view")
	cat <<'JSON'
{"number":7,"title":"Add feature","body":"Body","baseRefName":"main","headRefName":"feature-head","url":"https://github.com/acme/widgets/pull/7","state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","name":"unit tests","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"},{"__typename":"CheckRun","name":"e2e","status":"IN_PROGRESS","conclusion":null},{"__typename":"CheckRun","name":"codeql","status":"COMPLETED","conclusion":"ACTION_REQUIRED"},{"__typename":"CheckRun","name":"flaky","status":"COMPLETED","conclusion":"CANCELLED"},{"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"},{"__typename":"StatusContext","context":"ci/waiting","state":"EXPECTED"}]}
JSON
	;;
"pr diff")
	cat <<'DIFF'
diff --git a/foo.go b/foo.go
index 0000000..1111111 100644
--- a/foo.go
+++ b/foo.go
@@ -0,0 +1,2 @@
+package main
+func main() {}
DIFF
	;;
"api "*) echo "[]" ;;
*) exit 0 ;;
esac
GH
chmod +x "$bindir/gh"

cache=$(mktemp -d)
session_json=$(cd "$work" && PATH="$bindir:$PATH" XDG_CACHE_HOME="$cache" \
	AGENTS_DIR="$SCRIPT_DIR/../agents" \
	"$RC_TIMEOUT_BIN" 120 bash "$SCRIPTS/rc-prepare.sh" \
	--mode code --scope url \
	--scope-value "https://github.com/acme/widgets/pull/7" 2>/dev/null || echo '{}')
session=$(echo "$session_json" | jq -r '.session_dir // ""')

if [[ -z "$session" || ! -d "$session" ]]; then
	echo "  FAIL: prepare did not produce a session (got: $session_json)"
	FAIL=$((FAIL + 1))
else
	ci="$session/ci-status.txt"
	if [[ -f "$ci" ]]; then
		echo "  PASS: ci-status.txt written for an Actions-only PR"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: ci-status.txt missing — Quality Gates has no CI data"
		FAIL=$((FAIL + 1))
	fi

	# Read one row's grade out of the CI table and assert on it. The lookup is
	# a plain assignment rather than a nested command substitution so a failing
	# grep aborts the assertion instead of silently asserting against "".
	#
	# `[|]` rather than `\|`: inside an ERE a backslash-escaped pipe is a GNU
	# extension that BSD sed reads as a literal backslash.
	assert_grade() {
		local check="$1" expected="$2" label="$3" row actual
		row=$(grep -m1 "^| $check |" "$ci" 2>/dev/null || true)
		actual=$(sed -E 's/^[|] .* [|] (.*) [|]$/\1/' <<<"$row")
		assert_equals "$actual" "$expected" "$label"
	}
	assert_grade 'unit tests' "pass" "SUCCESS grades pass"
	assert_grade 'lint' "fail" "FAILURE grades fail"
	assert_grade 'e2e' "pending" "in-flight check grades pending"
	assert_grade 'codeql' "fail" "ACTION_REQUIRED grades fail"
	assert_grade 'flaky' "unknown" "CANCELLED carries no signal"
	assert_grade 'ci/legacy' "fail" "ERROR grades fail"
	assert_grade 'ci/waiting' "pending" "EXPECTED grades pending"

	failing=$(sed -n '/^## Failing Checks$/,$p' "$ci" | grep -c '^### ' || true)
	assert_equals "$failing" "3" "each failing check gets its own section"
fi

rm -rf "$work" "$bindir" "$cache"

# --------------------------------------------------------------------------
# Context capabilities: the adapter normalizes forge JSON so the stage that
# renders it never learns a forge's field names.
# --------------------------------------------------------------------------

# Call one context capability against a canned `gh api` payload and print the
# normalized JSON it returns.
# Usage: json=$(github_context_call rc_forge_fetch_reviews '<one page of the gh api payload>')
github_context_call() {
	local fn="$1" payload="$2" bindir
	bindir=$(mktemp -d)
	printf '%s\n' "$payload" >"$bindir/payload"
	# <payload> is one page. Asked to --slurp, gh wraps the pages in an outer
	# array, so the single page is wrapped here; a payload that is not JSON
	# stays not JSON either way.
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
case "\$1" in
"api" | "issue")
	if [[ " \$* " == *" --slurp "* ]]; then
		printf '['
		cat "$bindir/payload"
		printf ']\n'
	else
		cat "$bindir/payload"
	fi
	;;
*) exit 0 ;;
esac
GH
	chmod +x "$bindir/gh"
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/github.sh
		source "$FORGE_DIR/github.sh"
		"$fn" 7 acme widgets
	)
	rm -rf "$bindir"
}

echo "Test 10: reviews are normalized to author/state/submitted_at/body"
actual=$(github_context_call rc_forge_fetch_reviews \
	'[{"user":{"login":"alice"},"state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T00:00:00Z","body":"needs work"}]')
assert_jq_str "$actual" '.[0].author' "alice" "review author normalized off .user.login"
assert_jq_str "$actual" '.[0].state' "CHANGES_REQUESTED" "review state normalized"
assert_jq_str "$actual" '.[0].submitted_at' "2026-01-01T00:00:00Z" "review timestamp normalized"
assert_jq_str "$actual" '.[0].body' "needs work" "review body normalized"

echo "Test 11: inline comments are normalized to file/line/author/body"
actual=$(github_context_call rc_forge_fetch_review_comments \
	'[{"path":"api/client.go","line":null,"original_line":42,"user":{"login":"bob"},"body":"nit"}]')
assert_jq_str "$actual" '.[0].file' "api/client.go" "comment file normalized off .path"
assert_jq_str "$actual" '.[0].line' "42" "comment line falls back to original_line"
assert_jq_str "$actual" '.[0].author' "bob" "comment author normalized"

echo "Test 12: conversation comments are normalized to author/created_at/body"
actual=$(github_context_call rc_forge_fetch_conversation \
	'[{"user":{"login":"carol"},"created_at":"2026-02-02T00:00:00Z","body":"ping"}]')
assert_jq_str "$actual" '.[0].author' "carol" "conversation author normalized"
assert_jq_str "$actual" '.[0].created_at' "2026-02-02T00:00:00Z" "conversation timestamp normalized"

echo "Test 13: an unreachable forge yields an empty array, never malformed JSON"
# Preparation must survive a forge that is down; every capability degrades to
# "no context" rather than aborting the run or emitting something jq cannot read.
for fn in rc_forge_fetch_reviews rc_forge_fetch_review_comments rc_forge_fetch_conversation; do
	actual=$(github_context_call "$fn" 'not json at all')
	len=$(jq -r 'length' <<<"$actual" 2>/dev/null || echo "MALFORMED")
	assert_equals "$len" "0" "$fn degrades to an empty array"
done

# Call one context capability against a fake gh that serves <pages> (a JSON
# array of pages) the way GitHub does: the first page alone without
# --paginate, every page with it, wrapped in one outer array with --slurp.
# <mode> `fail` exits non-zero after printing, as a call cut off mid-listing
# does; `empty` prints nothing and exits 0. Prints what the capability returns.
# Usage: json=$(github_paged_call <fn> <pages-json> [fail|empty])
github_paged_call() {
	local fn="$1" pages="$2" mode="${3:-ok}" bindir
	bindir=$(mktemp -d)
	printf '%s\n' "$pages" >"$bindir/pages.json"
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
args=" \$* "
[[ "$mode" == "empty" ]] && exit 0
if [[ "\$args" != *" --paginate "* ]]; then
	jq -c '.[0]' "$bindir/pages.json"
elif [[ "\$args" == *" --slurp "* ]]; then
	jq -c . "$bindir/pages.json"
else
	jq -c '.[]' "$bindir/pages.json"
fi
[[ "$mode" == "fail" ]] && exit 1
exit 0
GH
	chmod +x "$bindir/gh"
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/github.sh
		source "$FORGE_DIR/github.sh"
		"$fn" 7 acme widgets
	)
	rm -rf "$bindir"
}

echo "Test 13b: every page of a long list is read, in order (RC-074)"
# A PR with 110 comments was read as its oldest 30: the replies posted since
# the council's latest verdict were never seen, the newest least of all.
two_pages=$(jq -nc '[
	[range(0; 100) | {user: {login: "filler"}, created_at: "2026-02-01T00:00:00Z",
		submitted_at: "2026-02-01T00:00:00Z", path: "a.go", line: 1, state: "COMMENTED", body: "x"}],
	[{user: {login: "dave"}, created_at: "2026-02-03T00:00:00Z",
		submitted_at: "2026-02-03T00:00:00Z", path: "b.go", line: 2, state: "COMMENTED", body: "newest"}]
]')
for fn in rc_forge_fetch_reviews rc_forge_fetch_review_comments rc_forge_fetch_conversation; do
	actual=$(github_paged_call "$fn" "$two_pages")
	assert_jq_str "$actual" 'length' "101" "$fn reads both pages"
	assert_jq_str "$actual" '.[100].body' "newest" "$fn keeps page order"
done

echo "Test 13c: a page that is not an array, or a cut-off listing, yields [] (RC-074)"
# An error body among the pages, or a call that failed after page 1, is a
# truncated list. A partial timeline can move the "latest verdict" anchor, so
# the adapter returns no context rather than some of it.
bad_page=$(jq -nc '[[{user: {login: "a"}, created_at: "", body: "x"}], {message: "Server Error"}]')
null_page=$(jq -nc '[[{user: {login: "a"}, created_at: "", body: "x"}], null]')
one_page=$(jq -nc '[[{user: {login: "a"}, created_at: "", body: "x"}]]')
for fn in rc_forge_fetch_reviews rc_forge_fetch_review_comments rc_forge_fetch_conversation; do
	actual=$(github_paged_call "$fn" "$bad_page")
	assert_jq_str "$actual" 'length' "0" "$fn rejects an error page"
	actual=$(github_paged_call "$fn" "$null_page")
	assert_jq_str "$actual" 'length' "0" "$fn rejects a null page"
	actual=$(github_paged_call "$fn" "$one_page" fail)
	assert_jq_str "$actual" 'length' "0" "$fn rejects a failed listing"
	actual=$(github_paged_call "$fn" "$one_page" empty)
	assert_jq_str "$actual" 'length' "0" "$fn returns [] when gh prints nothing"
done

# --------------------------------------------------------------------------
# The GitLab adapter's identity capability.
#
# `rc_forge_current_user` is what lets the re-review filter tell the council's
# own verdict apart from a reply that quotes it. Get it wrong on GitLab and the
# author test never matches, so the council re-ingests its own verdict into
# pr-conversation.txt as participant input to the Disposition phase. GitHub's
# implementation is exercised end to end by test-rc-prepare-conversation.sh;
# GitLab's had no caller at all, only a doc guard grepping for the name.
# --------------------------------------------------------------------------

# Call one capability from the gitlab adapter against a canned `glab api`
# payload and print what it returns. Mirrors github_context_call; the optional
# third argument makes the fake CLI exit non-zero, which is how an
# unauthenticated or rate-limited forge presents itself.
# Any further arguments are passed to the capability. Every non-`api` glab
# call (`auth status` included) succeeds.
# Usage: login=$(gitlab_context_call rc_forge_current_user '<glab api payload>' [cli_exit] [arg...])
gitlab_context_call() {
	local fn="$1" payload="$2" cli_exit="${3:-0}" bindir status
	# Without this an "empty on failure" case passes when the adapter is missing
	# entirely — a deleted implementation and a correctly empty result look the
	# same from outside.
	[[ -f "$FORGE_DIR/gitlab.sh" ]] || {
		echo "ERROR: adapter not found: $FORGE_DIR/gitlab.sh" >&2
		exit 1
	}
	bindir=$(mktemp -d)
	cat >"$bindir/glab" <<GLAB
#!/usr/bin/env bash
case "\$1" in
"api")
	cat <<'JSON'
${payload}
JSON
	exit ${cli_exit}
	;;
*) exit 0 ;;
esac
GLAB
	chmod +x "$bindir/glab"
	status=0
	# shellcheck disable=SC2310 # Capturing the exit status is what this helper is
	# for, and capturing it costs errexit inside the subshell. That is the trade.
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/gitlab.sh
		source "$FORGE_DIR/gitlab.sh"
		# A project on gitlab.com, as preparation resolves one: without it the
		# adapter makes no call, and the empty-result cases would pass unexercised.
		forge_owner=acme forge_repo=widgets
		"$fn" "${@:4}"
	) || status=$?
	rm -rf "$bindir"
	return "$status"
}

echo "Test 14: the GitLab adapter returns the bare username"
# GitLab's user payload carries both `.username` (the handle that authors a
# comment, which is what the author test compares against) and `.name` (the
# display name, which never appears as an author). Reading the wrong one yields
# a plausible non-empty string that matches nothing.
actual=$(gitlab_context_call rc_forge_current_user \
	'{"id":42,"username":"review-council-bot","name":"Review Council","state":"active"}')
assert_equals "$actual" "review-council-bot" "current user read off .username, not .name"

echo "Test 15: a GitLab user payload carrying no username yields nothing"
# Without the `// empty` guard jq prints the literal string `null` — a non-empty
# login that authored nothing, so the filter falls back to marker-only matching
# and discloses `null` as the account it tried, sending a maintainer looking for
# a user that never existed.
actual=$(gitlab_context_call rc_forge_current_user '{"id":42,"name":"Review Council"}')
assert_equals "$actual" "" "a payload without .username yields no login, not 'null'"

echo "Test 16: a malformed GitLab user payload yields empty output and exit 0"
rc=0
# shellcheck disable=SC2310 # The exit status is half of what this case asserts.
actual=$(gitlab_context_call rc_forge_current_user 'not json at all') || rc=$?
assert_equals "$actual" "" "unparseable user payload yields no login"
assert_equals "$rc" "0" "unparseable user payload does not abort preparation"

echo "Test 17: a failing GitLab user call yields empty output and exit 0"
# The other empty-on-failure branch: `glab api user` itself refusing, which is
# what a missing or expired token looks like. Preparation must read this as "no
# login" and fall back to marker-only matching, not as a reason to stop.
rc=0
# shellcheck disable=SC2310 # The exit status is half of what this case asserts.
actual=$(gitlab_context_call rc_forge_current_user '' 1) || rc=$?
assert_equals "$actual" "" "a failing user call yields no login"
assert_equals "$rc" "0" "a failing user call does not abort preparation"

echo "Test 18: the GitLab host gate admits a host glab is logged in to"
actual=$(gitlab_context_call rc_forge_host_refusal '' 0 git.example.org)
assert_equals "$actual" "" "logged-in host yields no refusal"

# `glab auth status --hostname ""` checks every configured host and can exit 0,
# so an empty host would pass a gate that only asked glab.
echo "Test 19: the GitLab host gate refuses an empty host itself"
actual=$(gitlab_context_call rc_forge_host_refusal '' 0 "")
if [[ -n "$actual" ]]; then
	echo "  PASS: empty host yields a refusal"
	PASS=$((PASS + 1))
else
	echo "  FAIL: empty host yields no refusal"
	FAIL=$((FAIL + 1))
fi

# Both refusals keep the credentials home; the wording must tell the user which
# fix applies, as scripts/lib/forge-gitlab.sh does by matching the same output.
gitlab_refusal_with_status() {
	local status_text="$1" bindir
	bindir=$(mktemp -d)
	cat >"$bindir/glab" <<GLAB
#!/usr/bin/env bash
echo '${status_text}' >&2
exit 1
GLAB
	chmod +x "$bindir/glab"
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/gitlab.sh
		source "$FORGE_DIR/gitlab.sh"
		rc_forge_host_refusal git.example.org
	)
	rm -rf "$bindir"
}

# Substring checks on $actual; a plain `[[ ]]` keeps the verdict out of a command substitution.
assert_message_has() { # needle label
	if [[ "$actual" == *"$1"* ]]; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 (got '$actual')"
		FAIL=$((FAIL + 1))
	fi
}
assert_message_lacks() { # needle label
	if [[ "$actual" != *"$1"* ]]; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 (got '$actual')"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test 19b: the GitLab host gate says login is missing when glab does not know the host"
actual=$(gitlab_refusal_with_status 'x git.example.org has not been authenticated with glab')
assert_message_has "is not logged in to git.example.org" "unknown host asks for glab auth login"
assert_message_has "glab auth login --hostname git.example.org" "unknown host names the login command"

echo "Test 19c: the GitLab host gate says login could not be confirmed when glab knows the host"
actual=$(gitlab_refusal_with_status 'x failed to reach git.example.org: connection refused')
assert_message_has "could not confirm a login for git.example.org" "configured but failing host is not called unconfigured"
assert_message_has "Refusing" "failing host is still refused"
assert_message_lacks "is not logged in" "failing host does not claim a missing login"

# --------------------------------------------------------------------------
# The GitLab adapter addresses the merge request by host and project.
#
# glab resolves an unaddressed call from the current directory's remote and its
# own default host, so a review of an MR by URL from anywhere else read some
# other project's MR 7 — or the same path on gitlab.com instead of the
# self-hosted instance the URL named. And glab sends its token to whatever host
# it is pointed at, so the adapter must not reach an unconfigured one even when
# a caller skipped rc-prepare.sh's gate.
# --------------------------------------------------------------------------

# Run one gitlab adapter function with forge_host/forge_owner/forge_repo set as
# preparation sets them, against a fake glab that records its argv. The fake is
# logged in to the hosts in <logged-in>; `glab api` prints <payload> and exits
# <api-exit>. Sets ga_out (the function's stdout, then pr_title for
# rc_forge_fetch_pr) and ga_calls (one glab argv per line).
#
# The caller's GitLab token variables never reach the fake; `NAME=value` words
# in the ga_env array are exported in their place. ga_tokens records, per glab
# call, `<argv 1-2>: <token variables glab saw>` (or `none`); ga_apihost
# records `<argv 1-2>: <GITLAB_API_HOST glab saw>` (or `unset`), and
# ga_ciauto the same for GLAB_ENABLE_CI_AUTOLOGIN. The host
# variables glab reads are cleared the same way.
# Usage: gitlab_adapter_run <host> <owner> <repo> <logged-in> <payload> <api-exit> <fn> [arg...]
ga_out="" ga_calls="" ga_tokens="" ga_apihost="" ga_ciauto=""
ga_env=()
gitlab_adapter_run() {
	local host="$1" owner="$2" repo="$3" logged_in="$4" payload="$5" api_exit="$6" fn="$7" bindir
	shift 7
	bindir=$(mktemp -d)
	printf '%s' "$payload" >"$bindir/payload"
	cat >"$bindir/glab" <<GLAB
#!/usr/bin/env bash
echo "glab \$*" >>"$bindir/calls"
seen=""
for v in GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN; do
	[[ -n "\${!v:-}" ]] && seen="\$seen \$v"
done
echo "\$1 \$2:\${seen:- none}" >>"$bindir/tokens"
echo "\$1 \$2: \${GITLAB_API_HOST-unset}" >>"$bindir/apihost"
echo "\$1 \$2: \${GLAB_ENABLE_CI_AUTOLOGIN-unset}" >>"$bindir/ciauto"
case "\$1 \$2" in
"auth status")
	case " $logged_in " in
	*" \$4 "*) exit 0 ;;
	*) exit 1 ;;
	esac
	;;
"mr view")
	echo '{"title":"T","description":"B","target_branch":"main","source_branch":"feat","web_url":"u","state":"opened"}'
	;;
"mr diff") echo 'diff --git a/x b/x' ;;
"api "*)
	cat "$bindir/payload"
	exit $api_exit
	;;
esac
exit 0
GLAB
	chmod +x "$bindir/glab"
	ga_out=$(
		PATH="$bindir:$PATH"
		unset GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN GITLAB_API_HOST GITLAB_HOST GITLAB_URI GL_HOST \
			GLAB_ENABLE_CI_AUTOLOGIN
		for assignment in "${ga_env[@]+"${ga_env[@]}"}"; do
			export "${assignment?}"
		done
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck source=module/skills/review-council/scripts/lib/forge/gitlab.sh
		source "$FORGE_DIR/gitlab.sh"
		forge_host="$host" forge_owner="$owner" forge_repo="$repo"
		pr_title=""
		"$fn" "$@"
		printf '%s' "$pr_title"
	)
	ga_calls=$(cat "$bindir/calls" 2>/dev/null || true)
	ga_tokens=$(cat "$bindir/tokens" 2>/dev/null || true)
	ga_apihost=$(cat "$bindir/apihost" 2>/dev/null || true)
	ga_ciauto=$(cat "$bindir/ciauto" 2>/dev/null || true)
	rm -rf "$bindir"
}

# Assert one recorded glab argv, exactly, is among the calls.
# Usage: assert_glab_argv <argv> <label>
assert_glab_argv() {
	if grep -qxF -e "$1" <<<"$ga_calls"; then
		echo "  PASS: $2"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $2 (no '$1' in glab calls: '$ga_calls')"
		FAIL=$((FAIL + 1))
	fi
}

echo "Test 20: the MR view is addressed to the URL's host and nested project"
gitlab_adapter_run git.example.org g/sub p git.example.org '' 0 rc_forge_fetch_pr 7 g/sub p
assert_glab_argv "glab mr view 7 -R git.example.org/g/sub/p --output json" "mr view carries -R host/project"
assert_equals "$ga_out" "T" "mr view payload still populates pr_title"

echo "Test 21: the MR diff is addressed the same way, and asked for raw"
gitlab_adapter_run git.example.org g/sub p git.example.org '' 0 rc_forge_fetch_diff 7 g/sub p /dev/stdout
assert_glab_argv "glab mr diff 7 -R git.example.org/g/sub/p --raw" "mr diff carries -R host/project and --raw"
assert_equals "$ga_out" "diff --git a/x b/x" "mr diff output reaches the out file"

echo "Test 22: the current user is asked of the URL's host"
gitlab_adapter_run git.example.org g/sub p git.example.org '{"username":"bot"}' 0 rc_forge_current_user
assert_glab_argv "glab api --hostname git.example.org user" "user lookup carries --hostname"
assert_equals "$ga_out" "bot" "user lookup still returns the username"

echo "Test 23: an empty host defaults to gitlab.com, which needs no login check"
gitlab_adapter_run "" g p "" '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_calls" "glab mr view 7 -R gitlab.com/g/p --output json" "gitlab.com is addressed without a login check"

echo "Test 24: an unaddressable project is never left for glab to resolve"
# glab resolves an unaddressed call from the checkout's remotes, preferring
# `upstream` over origin, so a fork would review upstream's MR of the same
# number — possibly on another host, carrying a token bound elsewhere. With no
# project there is nothing to ask, so nothing is asked.
for fn in rc_forge_fetch_pr rc_forge_fetch_diff rc_forge_fetch_conversation rc_forge_current_user; do
	gitlab_adapter_run gitlab.com "" "" "" '{"username":"bot"}' 0 "$fn" 7 "" "" /dev/null
	assert_equals "$ga_calls" "" "$fn — no glab call without a project"
done
gitlab_adapter_run gitlab.com "" "" "" '[]' 0 rc_forge_fetch_conversation 7 "" ""
assert_equals "$ga_out" "[]" "conversation without a project is an empty array"
gitlab_adapter_run gitlab.com "" "" "" '{"username":"bot"}' 0 rc_forge_current_user
assert_equals "$ga_out" "" "current user without a project is empty"
gitlab_adapter_run gitlab.com "" "" "" '' 0 rc_forge_fetch_pr 7 "" ""
assert_equals "$ga_out" "" "MR metadata without a project is left untouched"
stale_diff=$(mktemp)
echo "stale" >"$stale_diff"
gitlab_adapter_run gitlab.com "" "" "" '' 0 rc_forge_fetch_diff 7 "" "" "$stale_diff"
stale_left=$(cat "$stale_diff")
assert_equals "$stale_left" "" "diff without a project leaves the out file empty"
rm -f "$stale_diff"

echo "Test 25: an unconfigured self-hosted host is never sent a request"
# Called without rc-prepare.sh's gate having run: the adapter asks itself.
for fn in rc_forge_fetch_pr rc_forge_fetch_diff rc_forge_fetch_conversation rc_forge_current_user; do
	gitlab_adapter_run git.evil.example g p git.example.org '{"username":"x"}' 0 "$fn" 7 g p /dev/null
	assert_equals "$ga_calls" "glab auth status --hostname git.evil.example" \
		"$fn — the login check is the only glab call"
done
gitlab_adapter_run git.evil.example g p git.example.org '' 0 rc_forge_fetch_conversation 7 g p
assert_equals "$ga_out" "[]" "a refused conversation is an empty array"

echo "Test 26: the conversation reads the project's notes on the URL's host"
gitlab_adapter_run git.example.org g/sub p git.example.org '[]' 0 rc_forge_fetch_conversation 7 g/sub p
assert_glab_argv \
	"glab api --hostname git.example.org --paginate projects/g%2Fsub%2Fp/merge_requests/7/notes?per_page=100&sort=asc&order_by=created_at" \
	"notes path is the URL-encoded project, oldest first"

echo "Test 27: the conversation merges pages, drops system notes, normalises time to UTC"
# Two pages back to back, as `glab api --paginate` emits them. GitLab.com
# stamps `.645Z`; a self-managed instance may stamp a local offset. The re-review
# window compares these as strings, so they must share one shape.
gitlab_adapter_run gitlab.com g p "" '[
 {"author":{"username":"alice"},"created_at":"2026-10-08T13:52:36.645Z","body":"first","system":false},
 {"author":{"username":"ghost"},"created_at":"2026-10-08T13:52:36.700Z","body":"added 1 commit","system":true}
][
 {"author":{"username":"bob"},"created_at":"2026-10-08T09:52:37.1-04:00","body":"second","system":false},
 {"author":{"username":"carol"},"created_at":"2026-10-08T19:22:38+0530","body":"third","system":false},
 {"created_at":"yesterday","system":false}
]' 0 rc_forge_fetch_conversation 7 g p
assert_equals "$ga_out" \
	'[{"author":"alice","created_at":"2026-10-08T13:52:36Z","body":"first"},{"author":"bob","created_at":"2026-10-08T13:52:37Z","body":"second"},{"author":"carol","created_at":"2026-10-08T13:52:38Z","body":"third"},{"author":"unknown","created_at":"","body":""}]' \
	"pages merged in order, system note dropped, Z/±HH:MM/±HHMM normalised, unparseable time emptied"

echo "Test 28: a failed or malformed notes listing is an empty array"
gitlab_adapter_run gitlab.com g p "" '[{"author":{"username":"a"},"created_at":"2026-10-08T13:52:36Z","body":"x"}]' 1 \
	rc_forge_fetch_conversation 7 g p
assert_equals "$ga_out" "[]" "a failing notes call yields [] even with partial output"
gitlab_adapter_run gitlab.com g p "" '[]{"message":"403 Forbidden"}' 0 rc_forge_fetch_conversation 7 g p
assert_equals "$ga_out" "[]" "a non-array page yields []"
gitlab_adapter_run gitlab.com g p "" 'not json at all' 0 rc_forge_fetch_conversation 7 g p
assert_equals "$ga_out" "[]" "an unparseable listing yields []"

# glab prefers a token from the environment over the one stored per host, and
# sends it to whichever configured host a call targets. A GITLAB_TOKEN minted
# for gitlab.com would otherwise ride along to a self-hosted instance — and
# `glab auth status` passes for any host merely present in glab's config, so
# the gate alone does not stop that. Each line below is "<call>: <vars seen>".
all_tokens=(GITLAB_TOKEN=t1 GITLAB_ACCESS_TOKEN=t2 OAUTH_TOKEN=t3)
seen_all="GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN"

echo "Test 29: env tokens never reach a host other than the one they are bound to"
ga_env=("${all_tokens[@]}")
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: none
mr view: none" "GITLAB_HOST unset — self-hosted calls, gate included, see no env token"
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_host_refusal git.example.org
assert_equals "$ga_tokens" "auth status: none" "the gate on its own sees no env token"

echo "Test 30: env tokens reach the host GITLAB_HOST binds them to"
ga_env=("${all_tokens[@]}" GITLAB_HOST=git.example.org)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "GITLAB_HOST=git.example.org — its calls see the env tokens"
ga_env=("${all_tokens[@]}" GITLAB_HOST=https://Git.Example.org/)
gitlab_adapter_run git.example.org g p git.example.org '[]' 0 rc_forge_fetch_conversation 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
api --hostname: ${seen_all}" "GITLAB_HOST given as a URL binds by its hostname"
# A port names a different service on the same name; the portless host the
# adapter addresses is not where glab would have sent that token.
ga_env=("${all_tokens[@]}" GITLAB_HOST=https://git.example.org:8443/)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: none
mr view: none" "GITLAB_HOST with a port does not bind the portless host"
# A scheme's own default port names the same service as no port at all, so it
# binds the portless host. Any other port, including the other scheme's
# default, still does not. GITLAB_API_HOST is host[:port] verbatim with no
# scheme to imply a default, so its port is always significant.
while IFS='|' read -r label assignment want; do
	ga_env=("${all_tokens[@]}" "$assignment")
	gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
	if [[ "$want" == "bound" ]]; then
		assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "$label — binds the portless host"
	else
		assert_equals "$ga_tokens" "auth status: none
mr view: none" "$label — does not bind the portless host"
	fi
done <<'DEFAULTPORTS'
GITLAB_HOST https default port|GITLAB_HOST=https://git.example.org:443/|bound
GITLAB_URI http default port|GITLAB_URI=http://git.example.org:80|bound
GL_HOST upper-case scheme default port|GL_HOST=HTTPS://git.example.org:443|bound
GITLAB_HOST http with port 443|GITLAB_HOST=http://git.example.org:443|unbound
GITLAB_HOST bare host with port 443|GITLAB_HOST=git.example.org:443|unbound
GITLAB_API_HOST with port 443|GITLAB_API_HOST=git.example.org:443|unbound
DEFAULTPORTS
ga_env=("${all_tokens[@]}" GITLAB_HOST=git.example.org)
gitlab_adapter_run gitlab.com g p "" '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "mr view: none" "GITLAB_HOST elsewhere — gitlab.com sees no env token"

echo "Test 31: with GITLAB_HOST unset the env tokens are gitlab.com's"
ga_env=("${all_tokens[@]}")
gitlab_adapter_run gitlab.com g p "" '{"username":"bot"}' 0 rc_forge_current_user
assert_equals "$ga_tokens" "api --hostname: ${seen_all}" "gitlab.com sees the env tokens"

# glab 1.102 reads its default host — the host an env token belongs to — from
# GITLAB_API_HOST, then GITLAB_HOST, then GITLAB_URI, then GL_HOST, ignoring an
# empty value. The binding follows the same order.
echo "Test 32: env tokens are bound by glab's own host precedence"
ga_env=("${all_tokens[@]}" GITLAB_API_HOST=git.example.org GITLAB_HOST=gitlab.com)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "GITLAB_API_HOST outranks GITLAB_HOST"
gitlab_adapter_run gitlab.com g p "" '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "mr view: none" "GITLAB_API_HOST elsewhere — gitlab.com sees no env token"
ga_env=("${all_tokens[@]}" GITLAB_URI=git.example.org GL_HOST=gitlab.com)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "GITLAB_URI outranks GL_HOST"
ga_env=("${all_tokens[@]}" GL_HOST=git.example.org)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "GL_HOST alone binds"
ga_env=("${all_tokens[@]}" GITLAB_HOST= GITLAB_URI=git.example.org)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_tokens" "auth status: ${seen_all}
mr view: ${seen_all}" "an empty GITLAB_HOST is skipped, as glab skips it"

# GITLAB_API_HOST redirects every glab request — explicit `--hostname` and `-R`
# included — so left in place it would aim the addressed calls at another
# instance. It is cleared for every call.
echo "Test 33: GITLAB_API_HOST never reaches glab"
ga_env=(GITLAB_API_HOST=elsewhere.example)
gitlab_adapter_run git.example.org g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_apihost" "auth status: unset
mr view: unset" "the gate and the call both run without GITLAB_API_HOST"

# Inside a GitLab CI job, GLAB_ENABLE_CI_AUTOLOGIN makes glab log in with the
# job's CI_JOB_TOKEN and point at the job's own instance, whatever the call
# names — the job token can reach another host, or the call another instance.
echo "Test 33a: GLAB_ENABLE_CI_AUTOLOGIN never reaches glab"
for target in git.example.org gitlab.com; do
	ga_env=(GLAB_ENABLE_CI_AUTOLOGIN=true GITLAB_CI=true CI_JOB_TOKEN=job CI_SERVER_HOST=ci.example.test)
	gitlab_adapter_run "$target" g p git.example.org '' 0 rc_forge_fetch_pr 7 g p
	want="mr view: unset"
	[[ "$target" == "gitlab.com" ]] || want="auth status: unset
${want}"
	assert_equals "$ga_ciauto" "$want" "$target — the gate and the call both run without CI autologin"
done
# The bound branch (env tokens kept) must clear it too.
ga_env=(GLAB_ENABLE_CI_AUTOLOGIN=true GITLAB_TOKEN=t1)
gitlab_adapter_run gitlab.com g p "" '' 0 rc_forge_fetch_pr 7 g p
assert_equals "$ga_ciauto" "mr view: unset" "a call keeping its env token still runs without CI autologin"
ga_env=()

# The gate is asked once per host per process. Asked per call, one transient
# failure emptied one artifact while its siblings were fetched, and a
# self-hosted run made the check five times.
ga_all_four() {
	rc_forge_fetch_pr 7 g p
	rc_forge_fetch_diff 7 g p /dev/null
	rc_forge_fetch_conversation 7 g p >/dev/null
	rc_forge_current_user >/dev/null
}
echo "Test 34: the login gate runs once per host"
gitlab_adapter_run git.example.org g p git.example.org '[]' 0 ga_all_four
auth_calls=$(grep -c '^glab auth status' <<<"$ga_calls" || true)
assert_equals "$auth_calls" "1" "four calls to an admitted host ask the gate once"
gitlab_adapter_run git.evil.example g p git.example.org '[]' 0 ga_all_four
assert_equals "$ga_calls" "glab auth status --hostname git.evil.example" "a refusal is remembered, not re-asked"

# The commit a review reads is the PR/MR head the forge reports, recorded so
# the posted marker names it: a marker of `sha=unknown` reads as never
# reviewed, and a checkout's own HEAD is not the PR's when the review ran by
# URL. Only a full 40-hex commit id is kept; anything else leaves it empty.
# Usage: head_sha_for <github|gitlab> <json value of the sha field>
head_sha_for() {
	local forge="$1" value="$2" bindir
	bindir=$(mktemp -d)
	if [[ "$forge" == "github" ]]; then
		# headRefOid is only in the payload when it was asked for.
		cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
oid=""
[[ " \$* " == *headRefOid* ]] && oid=',"headRefOid":${value}'
echo "{\"title\":\"T\",\"headRefName\":\"feat\"\${oid},\"statusCheckRollup\":[]}"
GH
	else
		cat >"$bindir/glab" <<GLAB
#!/usr/bin/env bash
echo '{"title":"T","source_branch":"feat","sha":${value}}'
GLAB
	fi
	chmod +x "$bindir"/*
	(
		PATH="$bindir:$PATH"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck disable=SC1090 # one of the two adapters, chosen per case.
		source "$FORGE_DIR/${forge}.sh"
		forge_host="gitlab.com"
		pr_head_sha="stale"
		rc_forge_fetch_pr 7 acme widgets
		printf '%s' "$pr_head_sha"
	)
	rm -rf "$bindir"
}

echo "Test 35: rc_forge_fetch_pr records the head commit id"
good=0123456789abcdef0123456789abcdef01234567
for tc_forge in github gitlab; do
	got=$(head_sha_for "$tc_forge" "\"$good\"")
	assert_equals "$got" "$good" "$tc_forge: a 40-hex head sha is kept"
	for bad in '"0123456"' '"0123456789ABCDEF0123456789ABCDEF01234567"' '"--x"' 'null' '"'"$good"'\nx"'; do
		got=$(head_sha_for "$tc_forge" "$bad")
		assert_equals "$got" "" "$tc_forge: head sha $bad is dropped"
	done
done

# --------------------------------------------------------------------------
# rc_forge_fetch_links: every symlink in the head tree, or nothing (RC-078).
#
# rc-check-symlinks.sh judges a change against this list, so a partial one would
# hide a chain through a link it left out. Each adapter must print the whole
# list and return 0, or print nothing and return non-zero.
# --------------------------------------------------------------------------

links_head=0123456789abcdef0123456789abcdef01234567
link_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
link_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# Run rc_forge_fetch_links from the <forge> adapter against a fake CLI that
# answers the tree request with <fixture>/tree (gh's response, or glab's pages
# back to back) and a blob request for <id> with <fixture>/blob-<id>, failing
# when that file is absent. <cap>, when given, is REVIEW_COUNCIL_MAX_HEAD_LINKS.
# Sets links_out to what the capability printed and links_rc to its status.
# Usage: links_call <github|gitlab> <fixture> [cap]
links_out="" links_rc=0
links_call() {
	local forge="$1" fixture="$2" cap="${3:-}" cli=gh bindir
	[[ "$forge" == "gitlab" ]] && cli=glab
	bindir=$(mktemp -d)
	cat >"$bindir/$cli" <<FAKE
#!/usr/bin/env bash
for arg in "\$@"; do
	case "\$arg" in
	*/trees/${links_head}\?recursive=1 | */repository/tree\?recursive=true\&ref=${links_head}\&per_page=100)
		cat "$fixture/tree"
		exit 0
		;;
	*/blobs/*)
		id="\${arg#*/blobs/}"
		id="\${id%/raw}"
		[[ -f "$fixture/blob-\$id" ]] || exit 1
		cat "$fixture/blob-\$id"
		exit 0
		;;
	esac
done
exit 1
FAKE
	chmod +x "$bindir/$cli"
	links_rc=0
	# shellcheck disable=SC2310 # the status is captured into links_rc and asserted on.
	links_out=$(
		PATH="$bindir:$PATH"
		[[ -z "$cap" ]] || export REVIEW_COUNCIL_MAX_HEAD_LINKS="$cap"
		# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
		source "$SCRIPTS/rc-lib.sh"
		rc_require_timeout
		# shellcheck disable=SC1090 # one of the two adapters, chosen per case.
		source "$FORGE_DIR/${forge}.sh"
		forge_host="gitlab.com"
		rc_forge_fetch_links 7 acme widgets "$links_head"
	) || links_rc=$?
	rm -rf "$bindir"
}

# A GitHub blob response: base64 of <bytes>, wrapped at 60 columns as GitHub does.
gh_blob() { # bytes, with printf %b escapes
	local content
	content=$(printf '%b' "$1" | base64 | tr -d '\n' | fold -w 60)
	jq -n --arg c "$content"$'\n' '{sha: "x", size: 1, encoding: "base64", content: $c}'
}

echo "Test 36: GitHub lists every link in the head tree with its target (RC-078)"
fx=$(mktemp -d)
jq -n --arg a "$link_a" --arg b "$link_b" '{sha: "t", truncated: false, tree: [
	{path: "README", mode: "100644", type: "blob", sha: $b},
	{path: "docs", mode: "040000", type: "tree", sha: $a},
	{path: "docs/l", mode: "120000", type: "blob", sha: $a},
	{path: "top", mode: "120000", type: "blob", sha: $b}]}' >"$fx/tree"
gh_blob "../$(printf 'r%.0s' {1..70})" >"$fx/blob-$link_a"
gh_blob 'docs' >"$fx/blob-$link_b"
links_call github "$fx"
assert_equals "$links_rc" "0" "the list is complete"
assert_equals "$links_out" \
	"[{\"path\":\"docs/l\",\"target\":\"../$(printf 'r%.0s' {1..70})\"},{\"path\":\"top\",\"target\":\"docs\"}]" \
	"both links, the one in a subdirectory too, with wrapped base64 decoded"

echo "Test 37: GitHub — a NUL byte or an unreadable blob is a null target (RC-078)"
gh_blob '/etc/shadow\0junk' >"$fx/blob-$link_a"
rm -f "$fx/blob-$link_b"
links_call github "$fx"
assert_equals "$links_rc" "0" "the list is still complete"
assert_equals "$links_out" '[{"path":"docs/l","target":null},{"path":"top","target":null}]' \
	"neither target is guessed"

echo "Test 38: GitHub — a truncated tree, or more links than the cap, is no list (RC-078)"
links_call github "$fx" 1
assert_equals "$links_rc:$links_out" "1:" "over REVIEW_COUNCIL_MAX_HEAD_LINKS: non-zero, no output"
jq '.truncated = true' "$fx/tree" >"$fx/tree.new"
mv "$fx/tree.new" "$fx/tree"
links_call github "$fx"
assert_equals "$links_rc:$links_out" "1:" "a truncated tree: non-zero, no output"
rm -rf "$fx"

echo "Test 39: GitLab lists every link across pages, target bytes exact (RC-078)"
fx=$(mktemp -d)
{
	jq -nc --arg a "$link_a" '[{id: $a, name: "docs", type: "tree", path: "docs", mode: "040000"},
		{id: $a, name: "l", type: "blob", path: "docs/l", mode: "120000"}]'
	jq -nc --arg b "$link_b" '[{id: $b, name: "top", type: "blob", path: "top", mode: "120000"},
		{id: $b, name: "README", type: "blob", path: "README", mode: "100644"}]'
} >"$fx/tree"
printf '../README' >"$fx/blob-$link_a"
printf 'docs\n' >"$fx/blob-$link_b"
links_call gitlab "$fx"
assert_equals "$links_rc" "0" "the list is complete"
assert_equals "$links_out" '[{"path":"docs/l","target":"../README"},{"path":"top","target":"docs\n"}]' \
	"both pages read, the subdirectory link kept, a trailing newline kept"

echo "Test 40: GitLab — a NUL byte or an unreadable blob is a null target (RC-078)"
printf '/etc/shadow\0junk' >"$fx/blob-$link_a"
rm -f "$fx/blob-$link_b"
links_call gitlab "$fx"
assert_equals "$links_rc" "0" "the list is still complete"
assert_equals "$links_out" '[{"path":"docs/l","target":null},{"path":"top","target":null}]' \
	"neither target is guessed"

echo "Test 41: GitLab — an error page, no answer, or more links than the cap is no list (RC-078)"
links_call gitlab "$fx" 1
assert_equals "$links_rc:$links_out" "1:" "over REVIEW_COUNCIL_MAX_HEAD_LINKS: non-zero, no output"
printf '[]{"message":"500 Internal Server Error"}' >"$fx/tree"
links_call gitlab "$fx"
assert_equals "$links_rc:$links_out" "1:" "an error page among the pages: non-zero, no output"
: >"$fx/tree"
links_call gitlab "$fx"
assert_equals "$links_rc:$links_out" "1:" "an empty answer: non-zero, no output"
rm -rf "$fx"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
