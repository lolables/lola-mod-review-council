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
*--json\ comments*) : ;; # no prior council comment => both PRs are unreviewed
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

	set +e
	if [[ "$input" == "__eof__" ]]; then
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" </dev/null 2>&1)
	else
		OUT=$(cd "$work" && env "${RUN_ENV[@]}" PATH="$bin:$masked" "$RC_TIMEOUT_BIN" 30 bash "$SCRIPT" "$@" <<<"$input" 2>&1)
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
