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
# Usage: json=$(github_context_call rc_forge_fetch_reviews '<gh api payload>')
github_context_call() {
	local fn="$1" payload="$2" bindir
	bindir=$(mktemp -d)
	cat >"$bindir/gh" <<GH
#!/usr/bin/env bash
case "\$1" in
"api" | "issue")
	cat <<'JSON'
${payload}
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
# Usage: login=$(gitlab_context_call rc_forge_current_user '<glab api payload>' [cli_exit])
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
		"$fn"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
