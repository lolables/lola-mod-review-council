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

echo "Test 5: each suite is announced, with its position, before it runs"
# The runner captures a suite's output and prints it only once the suite exits,
# so without an announcement a slow suite looks like a hung `task check`.
out=$(bash "$RUNNER" "$work/test-alpha.sh" "$work/test-beta.sh" 2>&1) || true
first_line=$(head -1 <<<"$out")
assert_equals "$first_line" "--> test-alpha.sh (1/2)" "the first suite is announced before any output"
beta_announced=$(grep -cxF -- '--> test-beta.sh (2/2)' <<<"$out") || beta_announced=0
assert_equals "$beta_announced" "1" "the second suite is announced with its position"

make_suite gamma 0 0
make_suite delta 0 0
four=("$work/test-alpha.sh" "$work/test-beta.sh" "$work/test-gamma.sh" "$work/test-delta.sh")

# ran() for each name, concatenated: one plain call, for the same SC2312 reason.
ran_each() { # name... -> yes|no per name
	local name
	for name in "$@"; do
		ran "$name"
	done
}

echo "Test 6: shards are disjoint and together run every suite once"
# CI runs the unit layer as one job per shard. A suite that falls in no shard
# never runs in CI, and nothing else would say so.
rm -f "$work"/ran-*
UNIT_SHARD=1/2 bash "$RUNNER" "${four[@]}" >/dev/null 2>&1 && status=0 || status=$?
assert_equals "$status" "0" "shard 1/2 exits 0"
first=$(ran_each alpha beta gamma delta)
assert_equals "$first" "yesnoyesno" "shard 1/2 runs the 1st and 3rd suites (round-robin)"
rm -f "$work"/ran-*
UNIT_SHARD=2/2 bash "$RUNNER" "${four[@]}" >/dev/null 2>&1 && status=0 || status=$?
assert_equals "$status" "0" "shard 2/2 exits 0"
second=$(ran_each alpha beta gamma delta)
assert_equals "$second" "noyesnoyes" "shard 2/2 runs the 2nd and 4th suites"

echo "Test 7: a sharded run says it is a shard, and counts only its suites"
# "Suites run: 2" alone would read as the whole selection.
out=$(UNIT_SHARD=2/2 bash "$RUNNER" "${four[@]}" 2>&1) || true
shard_lines=$(grep -cxE 'Shard: +2/2 \(2 of 4 suites\)' <<<"$out") || shard_lines=0
assert_equals "$shard_lines" "1" "the summary names the shard and the full count"
summary_lines=$(grep -cE '^Suites run: +2$' <<<"$out") || summary_lines=0
assert_equals "$summary_lines" "1" "the summary counts the shard's suites"
first_line=$(head -1 <<<"$out")
assert_equals "$first_line" "--> test-beta.sh (1/2)" "positions count within the shard"

echo "Test 8: a malformed shard is an error that runs nothing"
# A typo in the workflow must fail its job, not run an empty or partial shard
# that reports success.
for spec in 0/2 3/2 2 a/b 1/0 1/2/3 ' 1/2' 01/2; do
	rm -f "$work"/ran-*
	UNIT_SHARD="$spec" bash "$RUNNER" "${four[@]}" >/dev/null 2>&1 && status=0 || status=$?
	assert_equals "$status" "1" "UNIT_SHARD='$spec' fails the run"
	ran_any=$(ran_each alpha beta gamma delta)
	assert_equals "$ran_any" "nononono" "UNIT_SHARD='$spec' runs no suite"
done

echo "Test 9: a shard left with no suites is an error"
# More shards than suites means the split no longer fits the tree; "0 failed"
# from an empty shard would be true and say nothing.
UNIT_SHARD=3/3 bash "$RUNNER" "$work/test-alpha.sh" "$work/test-beta.sh" >/dev/null 2>&1 &&
	status=0 || status=$?
assert_equals "$status" "1" "an empty shard fails the run"

# Discovery with no arguments is not re-tested here: it is what `task test:unit`
# runs on every CI leg, and asserting it would mean executing all 40 real
# suites — minutes, to re-check a path already covered by every run.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
