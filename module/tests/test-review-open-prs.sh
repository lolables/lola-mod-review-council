#!/usr/bin/env bash
# Guards the confirmation gate in scripts/review-open-prs.sh.
#
# The driver hands each queued PR to `claude --permission-mode bypassPermissions`
# with a prompt that tells the council to post its verdict without asking. By the
# time anything is visible, a public comment is already on someone's pull
# request. --run is therefore not enough on its own: the operator has to say yes
# to the queue they were just shown, or pass --yes to state that consent up
# front. These tests pin both halves, and the fail-closed behaviour in between
# (no answer, or any answer that is not "yes", posts nothing).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../../scripts/review-open-prs.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SCRIPT" ]] || {
	echo "ERROR: driver not found: $SCRIPT" >&2
	exit 1
}

# Which agent CLIs the next run_case should find on PATH. Both by default, so
# the detection tests set it and every other test exercises the normal machine.
STUB_CLIS="claude opencode"

# Build a temp bin dir whose gh answers every query the driver makes offline,
# and whose agent CLIs record their argv instead of spending real money.
# Two open PRs, neither previously reviewed, so the queue is always non-empty.
make_mockbin() {
	local dir="$1" log="$2" cli
	mkdir -p "$dir"
	cat >"$dir/gh" <<'MOCKGH'
#!/usr/bin/env bash
args="$*"
case "$args" in
auth\ status*) exit 0 ;;
*--json\ nameWithOwner*) echo "acme/widgets" ;;
pr\ list*) printf '2\tbbbbbbb\n1\taaaaaaa\n' ;;
# Single-PR target: `gh pr view <n> ... --json number,headRefOid`.
*--json\ number,headRefOid*) printf '%s\tccccccc\n' "$3" ;;
*--json\ comments*) : ;; # no prior council comment => both PRs are unreviewed
# Commit authorship, already reduced by --jq to one email per line. Silence
# unless the test declared some via MOCK_EMAILS, so the default is the
# lookup-returned-nothing case every pre-existing test relies on.
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
# Stand in for what the agent writes to stdout, so a test can drive whatever
# the driver renders from it. Silent unless the test asked for something.
[[ -n "\${MOCK_CLI_STDOUT:-}" ]] && printf '%s\n' "\$MOCK_CLI_STDOUT"
exit 0
MOCKCLI
		chmod +x "$dir/$cli"
	done
}

# Print a PATH with the real claude and opencode removed, so a test that stubs
# only one of them does not silently fall through to the developer's own
# install and assert against the wrong CLI.
mask_agent_clis() {
	local work="$1" saved="$PATH" masked
	masked=$(path_without_command claude "$work")
	PATH="$masked"
	masked=$(path_without_command opencode "$work")
	PATH="$saved"
	printf '%s' "$masked"
}

# run_case <stdin: __eof__ | text> <driver args...>
# Sets OUT (stdout+stderr), RC (exit status), CALLS (agent CLI invocations) and
# CMDS (the recorded argv of each). Honours STUB_CLIS and any RUN_ENV entries.
# Runs inside its own temp CWD: the driver writes ./.review-council-logs.
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

	set +e
	if [[ "$input" == "__eof__" ]]; then
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" MOCK_EMAILS_FILE="$emails_file" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" </dev/null 2>&1)
	else
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" MOCK_EMAILS_FILE="$emails_file" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" <<<"$input" 2>&1)
	fi
	RC=$?
	set -e

	CALLS=0
	CMDS=""
	if [[ -f "$log" ]]; then
		CALLS=$(grep -c . "$log" || true)
		CMDS=$(cat "$log")
	fi
	rm -rf "$work"
}

# Environment assignments prepended to the next run_case, as KEY=VALUE words.
RUN_ENV=()

# Commit authorship the next run_case's mock gh will report, as "<pr><TAB><email>"
# lines. Empty by default: a PR whose authorship cannot be determined must be
# reviewed, so every test that does not set this exercises the unfiltered path.
MOCK_EMAILS=""

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

echo "Test: --run without --yes warns about the GitHub edits and asks first"
run_case "__eof__" --repo acme/widgets --run
assert_contains "$OUT" "GitHub" "the warning names GitHub"
assert_contains "$OUT" "2 pull request" "the warning names how many PRs are affected"
assert_contains "$OUT" "acme/widgets" "the warning names the repository"
assert_contains "$OUT" "--yes" "the warning points at the flag that skips it"
assert_equals "$CALLS" "0" "no answer on stdin posts nothing"
assert_equals "$RC" "1" "an unconfirmed run exits non-zero"

echo ""
echo "Test: an explicit 'yes' proceeds"
run_case "yes" --repo acme/widgets --run
assert_equals "$CALLS" "2" "both queued PRs are reviewed"
assert_equals "$RC" "0" "a confirmed run exits clean"

echo ""
echo "Test: anything other than yes aborts"
for answer in no y "" Y3s; do
	run_case "$answer" --repo acme/widgets --run
	assert_equals "$CALLS" "0" "answer '${answer}' posts nothing"
	assert_equals "$RC" "1" "answer '${answer}' exits non-zero"
done

echo ""
echo "Test: --yes states the consent up front, no prompt"
run_case "__eof__" --repo acme/widgets --run --yes
assert_equals "$CALLS" "2" "--yes reviews both queued PRs with stdin closed"
assert_equals "$RC" "0" "--yes exits clean"

echo ""
echo "Test: --force alone does not waive the confirmation"
run_case "__eof__" --repo acme/widgets --run --force
assert_equals "$CALLS" "0" "--force is about re-reviewing, not about consent"
assert_equals "$RC" "1" "--force without --yes still stops at the prompt"

echo ""
echo "Test: a dry run posts nothing, so it never asks"
run_case "__eof__" --repo acme/widgets
assert_contains "$OUT" "DRY RUN" "the dry-run plan is printed"
assert_equals "$CALLS" "0" "a dry run invokes nothing"
assert_equals "$RC" "0" "a dry run with stdin closed still exits clean"

echo ""
echo "Test: --help documents the flags"
run_case "__eof__" --help
assert_contains "$OUT" "--yes" "usage lists --yes"
assert_contains "$OUT" "--cli" "usage lists --cli"

# ---- Agent CLI selection ----------------------------------------------------
# The council command is installed for both hosts, but they take it by different
# routes: claude expands a leading /review-council inside its -p prompt, while
# opencode names the command with --command and treats the message as its
# $ARGUMENTS. Getting that wrong sends the council's own arguments to the model
# as prose, which fails late and expensively, so the exact argv is asserted.
echo ""
echo "Test: claude wins when both CLIs are installed"
STUB_CLIS="claude opencode"
run_case "yes" --repo acme/widgets --run
assert_contains "$CMDS" "claude -p /review-council https://github.com/acme/widgets/pull/2 -- post the verdict, auto-send without asking --permission-mode bypassPermissions" \
	"claude is invoked with the slash command inside the prompt"
assert_equals "$RC" "0" "the batch completes"

echo ""
echo "Test: opencode is used when it is the only CLI installed"
STUB_CLIS="opencode"
run_case "yes" --repo acme/widgets --run
assert_contains "$CMDS" "opencode run --command review-council --auto https://github.com/acme/widgets/pull/2 -- post the verdict, auto-send without asking" \
	"opencode names the command with --command and passes the rest as arguments"
assert_not_contains "$CMDS" "--auto /review-council" "the command name is not repeated in the message"
assert_not_contains "$CMDS" "bypassPermissions" "claude's permission flag is not passed to opencode"
assert_equals "$RC" "0" "the batch completes"

echo ""
echo "Test: --cli picks the host when both are installed"
STUB_CLIS="claude opencode"
run_case "yes" --repo acme/widgets --run --cli opencode
assert_contains "$CMDS" "opencode run --command review-council --auto" "--cli opencode overrides the default"
assert_equals "$RC" "0" "the batch completes"

echo ""
echo "Test: a CLI that is asked for but absent is an error, not a fallback"
STUB_CLIS="opencode"
run_case "__eof__" --repo acme/widgets --run --cli claude
assert_contains "$OUT" "claude" "the error names the missing CLI"
assert_equals "$CALLS" "0" "nothing is run through the other CLI instead"
assert_equals "$RC" "1" "the run fails"

echo ""
echo "Test: an unknown --cli value is rejected"
STUB_CLIS="claude opencode"
run_case "__eof__" --repo acme/widgets --cli emacs
assert_contains "$OUT" "--cli must be one of" "the error lists the accepted values"
assert_equals "$RC" "2" "usage errors exit 2"

echo ""
echo "Test: no agent CLI at all is a precondition failure"
STUB_CLIS=""
run_case "__eof__" --repo acme/widgets
assert_contains "$OUT" "claude" "the error names claude"
assert_contains "$OUT" "opencode" "the error names opencode"
assert_equals "$RC" "1" "the run fails"

# ---- Per-CLI knobs ----------------------------------------------------------
# MAX_BUDGET_USD maps to a claude flag that opencode has no equivalent for.
# Dropping it silently would run the batch uncapped on the strength of a
# setting that says the opposite, so the mismatch stops the run instead.
echo ""
echo "Test: MAX_BUDGET_USD caps each claude review"
STUB_CLIS="claude opencode"
RUN_ENV=(MAX_BUDGET_USD=5)
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$CMDS" "--max-budget-usd 5" "the cap is passed through to claude"
assert_equals "$RC" "0" "the batch completes"

echo ""
echo "Test: MAX_BUDGET_USD with opencode refuses to run uncapped"
STUB_CLIS="opencode"
RUN_ENV=(MAX_BUDGET_USD=5)
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$OUT" "MAX_BUDGET_USD" "the error names the setting it cannot honour"
assert_equals "$CALLS" "0" "no PR is reviewed uncapped"
assert_equals "$RC" "2" "the run fails"

echo ""
echo "Test: each CLI has its own extra-args knob"
STUB_CLIS="claude opencode"
RUN_ENV=(EXTRA_CLAUDE_ARGS=--model=opus EXTRA_OPENCODE_ARGS=--model=zen)
run_case "yes" --repo acme/widgets --run
assert_contains "$CMDS" "--model=opus" "EXTRA_CLAUDE_ARGS reaches claude"
assert_not_contains "$CMDS" "--model=zen" "EXTRA_OPENCODE_ARGS does not leak into claude"
STUB_CLIS="opencode"
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$CMDS" "--model=zen" "EXTRA_OPENCODE_ARGS reaches opencode"
assert_not_contains "$CMDS" "--model=opus" "EXTRA_CLAUDE_ARGS does not leak into opencode"

# A council review runs for tens of minutes. Under claude's default text output
# a `-p` run emits nothing at all until the final message, so the tee'd log is
# empty for the whole run and an operator watching it cannot tell work from a
# wedge. Streaming structured events is therefore the default, not a knob.
echo ""
echo "Test: claude streams structured events so a run can be watched"
STUB_CLIS="claude opencode"
run_case "yes" --repo acme/widgets --run
assert_contains "$CMDS" "--output-format stream-json" "claude emits an event per step"
assert_contains "$CMDS" "--verbose" "stream-json under --print is rejected without it"

echo ""
echo "Test: opencode is left on its own output format"
STUB_CLIS="opencode"
run_case "yes" --repo acme/widgets --run
assert_not_contains "$CMDS" "--output-format" "claude's streaming flags do not leak into opencode"

# Two --output-format flags would leave the format decided by claude's own
# last-wins parsing rather than by the operator who asked for one.
echo ""
echo "Test: an operator-chosen output format replaces the streaming default"
STUB_CLIS="claude opencode"
RUN_ENV=(EXTRA_CLAUDE_ARGS="--output-format json")
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$CMDS" "--output-format json" "EXTRA_CLAUDE_ARGS picks the format"
assert_not_contains "$CMDS" "stream-json" "the default is dropped rather than duplicated"

# The events are for the log; the terminal gets one line per step made out of
# them. A stream nobody can read at a glance is the problem this is fixing, so
# the rendering is pinned rather than left to be discovered mid-run.
echo ""
echo "Test: streamed events are rendered as progress, not raw JSON"
STUB_CLIS="claude opencode"
RUN_ENV=(MOCK_CLI_STDOUT='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Task","input":{"subagent_type":"divisor-adversary-code","description":"Review auth"}}]}}
{"type":"result","subtype":"success","total_cost_usd":8.23456,"num_turns":57}')
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$OUT" "→ Task Review auth" "a dispatch is shown as one readable line"
assert_contains "$OUT" "done — \$8.23, 57 turns" "the run's cost and turn count close it out"
assert_not_contains "$OUT" '"type":"assistant"' "the raw event does not reach the terminal"

# stderr is merged into the same stream and is not JSON. A driver that renders
# only what parses would swallow exactly the output an operator needs when a
# run goes wrong.
echo ""
echo "Test: non-JSON output survives the renderer"
RUN_ENV=(MOCK_CLI_STDOUT='Error: something went wrong')
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
assert_contains "$OUT" "Error: something went wrong" "a diagnostic is passed through verbatim"

# ---- Ignoring PRs by author email -------------------------------------------
# Dependency bots open PRs faster than a council can review them, and each
# review costs real money, so their addresses are skipped by default. The rule
# is deliberately conservative: a PR is "from" an ignored address only when
# EVERY commit on it was authored by one. A maintainer who pushes a fix onto a
# Renovate PR has put human work in it, and that has to come back for review.
DEPENDABOT_EMAIL="49699333+dependabot[bot]@users.noreply.github.com"
RENOVATE_EMAIL="29139614+renovate[bot]@users.noreply.github.com"

echo ""
echo "Test: a PR authored entirely by dependabot is skipped by default"
MOCK_EMAILS="2	${DEPENDABOT_EMAIL}"
run_case "yes" --repo acme/widgets --run
MOCK_EMAILS=""
assert_contains "$OUT" "Ignored" "the plan reports the ignored PR"
assert_contains "$CMDS" "/pull/1" "the human PR is still reviewed"
assert_not_contains "$CMDS" "/pull/2" "the bot PR is not reviewed"
assert_equals "$CALLS" "1" "only the human PR costs a review"
assert_equals "$RC" "0" "the batch completes"

echo ""
echo "Test: renovate is ignored by default too"
MOCK_EMAILS="2	${RENOVATE_EMAIL}"
run_case "yes" --repo acme/widgets --run
MOCK_EMAILS=""
assert_not_contains "$CMDS" "/pull/2" "the renovate PR is not reviewed"
assert_equals "$CALLS" "1" "only the human PR costs a review"

echo ""
echo "Test: a bot PR with a human commit on top is still reviewed"
MOCK_EMAILS="2	${RENOVATE_EMAIL}
2	alice@corp.example"
run_case "yes" --repo acme/widgets --run
MOCK_EMAILS=""
assert_contains "$CMDS" "/pull/2" "one human commit brings the PR back into the queue"
assert_equals "$CALLS" "2" "both PRs are reviewed"

echo ""
echo "Test: authorship that cannot be determined fails open to reviewing"
MOCK_EMAILS=""
run_case "yes" --repo acme/widgets --run
assert_equals "$CALLS" "2" "an empty commit lookup never silently drops a PR"

echo ""
echo "Test: matching is case-insensitive"
MOCK_EMAILS="2	49699333+Dependabot[BOT]@Users.NoReply.GitHub.com"
run_case "yes" --repo acme/widgets --run
MOCK_EMAILS=""
assert_not_contains "$CMDS" "/pull/2" "case does not defeat the deny-list"
assert_equals "$CALLS" "1" "only the human PR costs a review"

echo ""
echo "Test: --ignore-email adds an address to the defaults"
MOCK_EMAILS="1	${DEPENDABOT_EMAIL}
2	ci@corp.example"
run_case "yes" --repo acme/widgets --run --ignore-email ci@corp.example
MOCK_EMAILS=""
assert_equals "$CALLS" "0" "the added address is skipped alongside the defaults"
assert_contains "$OUT" "Nothing to review" "an entirely ignored queue says so"
# Without this the assertion above is satisfied by the script rejecting
# --ignore-email as an unknown option, which is not the behaviour under test.
assert_equals "$RC" "0" "an empty queue is a clean exit, not a usage error"

echo ""
echo "Test: --ignore-email may be repeated"
MOCK_EMAILS="1	one@corp.example
2	two@corp.example"
run_case "yes" --repo acme/widgets --run --ignore-email one@corp.example --ignore-email two@corp.example
MOCK_EMAILS=""
assert_equals "$CALLS" "0" "both addresses take effect"
assert_equals "$RC" "0" "the flag is accepted twice, not rejected"

echo ""
echo "Test: --no-ignore-emails reviews the bots anyway"
MOCK_EMAILS="2	${DEPENDABOT_EMAIL}"
run_case "yes" --repo acme/widgets --run --no-ignore-emails
MOCK_EMAILS=""
assert_contains "$CMDS" "/pull/2" "the deny-list is cleared"
assert_equals "$CALLS" "2" "every open PR is reviewed"

echo ""
echo "Test: IGNORE_EMAILS replaces the defaults rather than extending them"
MOCK_EMAILS="1	${DEPENDABOT_EMAIL}
2	ci@corp.example"
RUN_ENV=(IGNORE_EMAILS=ci@corp.example)
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
MOCK_EMAILS=""
assert_contains "$CMDS" "/pull/1" "dependabot is no longer on the list"
assert_not_contains "$CMDS" "/pull/2" "the address that replaced it is"
assert_equals "$CALLS" "1" "exactly one PR is reviewed"

echo ""
echo "Test: an empty IGNORE_EMAILS disables the deny-list"
MOCK_EMAILS="2	${DEPENDABOT_EMAIL}"
RUN_ENV=(IGNORE_EMAILS=)
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
MOCK_EMAILS=""
assert_equals "$CALLS" "2" "an empty list ignores nobody"

echo ""
echo "Test: IGNORE_EMAILS accepts commas as well as whitespace"
MOCK_EMAILS="1	one@corp.example
2	two@corp.example"
# Quoted as one element: the comma is the separator under test, not an array
# separator (SC2054).
RUN_ENV=("IGNORE_EMAILS=one@corp.example,two@corp.example")
run_case "yes" --repo acme/widgets --run
RUN_ENV=()
MOCK_EMAILS=""
assert_equals "$CALLS" "0" "a comma-separated list is split"

echo ""
echo "Test: naming a single PR overrides the deny-list"
MOCK_EMAILS="2	${DEPENDABOT_EMAIL}"
run_case "yes" --repo acme/widgets 2 --run
MOCK_EMAILS=""
assert_contains "$CMDS" "/pull/2" "asking for one PR by number is unambiguous"
assert_equals "$CALLS" "1" "the named PR is reviewed"

echo ""
echo "Test: --ignore-email requires an argument"
run_case "__eof__" --repo acme/widgets --ignore-email
assert_contains "$OUT" "--ignore-email requires" "the error names the flag"
assert_equals "$RC" "2" "usage errors exit 2"

echo ""
echo "Test: --help documents the deny-list"
run_case "__eof__" --help
assert_contains "$OUT" "--ignore-email" "usage lists --ignore-email"
assert_contains "$OUT" "--no-ignore-emails" "usage lists --no-ignore-emails"
assert_contains "$OUT" "IGNORE_EMAILS" "usage documents the environment override"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
