#!/usr/bin/env bash
# Guards the suite-selection contract of .taskfiles/scripts/run-unit-tests.sh.
#
# The runner discovers suites rather than reading a hand-kept list, because a
# new test file nobody remembered to register never ran — silently, and
# indistinguishably from passing. Taking an explicit list of suites as
# arguments reopens exactly that hole if it goes wrong: a runner handed nine
# suites that runs zero of them prints the same "0 failed" as one that ran all
# nine and found nothing. The degraded layer relies on this to run its narrowed
# selection, so a defect here disarms that layer while leaving it green.
#
# Driven by invoking the real runner against throwaway fixture suites, so the
# assertions cover the shipped script rather than a copy of its logic.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/../../.taskfiles/scripts/run-unit-tests.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$RUNNER" ]] || {
	echo "ERROR: runner not found: $RUNNER" >&2
	exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Each fixture ends with the "Results: N passed, M failed" line the runner
# parses, and marks the run with a sentinel file so a suite that was skipped is
# distinguishable from one that ran and passed.
make_suite() { # name exit-status failed-count
	cat >"$work/test-$1.sh" <<-EOF
		#!/usr/bin/env bash
		touch "$work/ran-$1"
		echo "Results: 1 passed, $3 failed"
		exit $2
	EOF
}
make_suite alpha 0 0
make_suite beta 0 0
make_suite broken 1 1

# Did the named fixture suite run?
#
# Written as if/else and called through a plain assignment rather than inlined
# into the assertion as `$([[ -f ... ]] && echo yes || echo no)`. A command
# substitution nested inside another command has its exit status discarded
# (SC2312), so a check that broke would yield an empty string and read as a
# suite that did not run — which is one of the two answers this asserts.
ran() { # name -> yes|no
	if [[ -f "$work/ran-$1" ]]; then
		printf 'yes'
	else
		printf 'no'
	fi
}

# ---------------------------------------------------------------------------
echo "Test 1: named suites run and unnamed ones do not"
rm -f "$work"/ran-*
out=$(bash "$RUNNER" "$work/test-alpha.sh" 2>&1) && status=0 || status=$?
assert_equals "$status" "0" "a run of one passing suite exits 0"
actual=$(ran alpha)
assert_equals "$actual" "yes" "the named suite ran"
actual=$(ran beta)
assert_equals "$actual" "no" "the unnamed suite did not run"

echo "Test 2: the summary counts the suites actually run, not the tree"
# A count taken from the directory rather than from the run would report 41
# here and read as full coverage. That is the whole failure mode.
summary_lines=$(grep -cE '^Suites run: +1$' <<<"$out") || summary_lines=0
assert_equals "$summary_lines" "1" "the summary reports one suite"

echo "Test 3: a failing suite among the named ones fails the run"
rm -f "$work"/ran-*
bash "$RUNNER" "$work/test-alpha.sh" "$work/test-broken.sh" >/dev/null 2>&1 &&
	status=0 || status=$?
assert_equals "$status" "1" "a run including a failing suite exits 1"
actual=$(ran broken)
assert_equals "$actual" "yes" "the failing suite ran"

echo "Test 4: a named suite that does not exist is an error, not a silent skip"
# Passing a path the runner cannot read means the caller's selection is wrong.
# Ignoring it would run a smaller set than asked for and still report success.
bash "$RUNNER" "$work/test-absent.sh" >/dev/null 2>&1 && status=0 || status=$?
assert_equals "$status" "1" "an unreadable suite path fails the run"

# Discovery with no arguments is not re-tested here: it is what `task test:unit`
# runs on every CI leg, and asserting it would mean executing all 40 real
# suites — minutes, to re-check a path already covered by every run.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
