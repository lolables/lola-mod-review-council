#!/usr/bin/env bash
# Tests for the test harness itself — the helpers in helpers.sh that every
# suite builds its fixtures out of.
#
# A defect here does not announce itself. helpers.sh has no suite of its own to
# go red, so a helper that quietly stops doing its job weakens whichever
# assertions depend on it: the suite still runs, still prints PASS, and no
# longer tests what it says it tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

echo "Test 1: chained masking hides every named command"
# Two calls sharing one workdir is how a command with a Homebrew-prefixed alias
# gets hidden — `timeout`, then `gtimeout` over the PATH the first call
# returned. On a Mac both names sit in the same Homebrew bindir, so the second
# call is handed the first call's mirror of that directory, alias included, and
# has to mirror a mirror.
#
# Mirrors used to be numbered mask-1, mask-2, ... from zero on every call, which
# made the second call's first mirror the directory it was reading: every
# `ln -s` failed with "File exists", and the alias — already linked by the first
# call, and skipped as the exclusion by this one — survived masking. macOS CI
# failed on it three times over; Linux has no such alias, so no call there ever
# chained into a second mirror and the suite stayed green.
fakebin=$(mktemp -d)
for c in rc-probe grc-probe rc-probe-keep; do
	printf '#!/bin/sh\nexit 0\n' >"$fakebin/$c"
	chmod +x "$fakebin/$c"
done
maskdir=$(mktemp -d)
errfile=$(mktemp)
masked=$(PATH="$fakebin:$PATH" path_without_command rc-probe "$maskdir" 2>"$errfile")
masked=$(PATH="$masked" path_without_command grc-probe "$maskdir" 2>>"$errfile")

assert_equals "$(PATH="$masked" command -v rc-probe || true)" "" \
	"the first masked command does not resolve"
assert_equals "$(PATH="$masked" command -v grc-probe || true)" "" \
	"the second masked command does not resolve"
# Over-masking is the opposite failure and just as silent: a suite whose script
# under test dies at exit 127 reports a failed assertion, not a broken PATH.
if [[ -n "$(PATH="$masked" command -v rc-probe-keep || true)" ]]; then
	echo "  PASS: an unmasked neighbour still resolves"
	PASS=$((PASS + 1))
else
	echo "  FAIL: an unmasked neighbour was masked too"
	FAIL=$((FAIL + 1))
fi
# Read into a variable first: a command substitution nested inside another has
# its exit status discarded (SC2312), so a failing `cat` would assert against
# the empty string — which is exactly what this asserts is correct.
maskerr=$(cat "$errfile")
assert_equals "$maskerr" "" "masking reports no errors"
rm -rf "$fakebin" "$maskdir" "$errfile"

echo "Test: assert_idempotent passes for a command that rewrites identical content"
_h_state=$(mktemp -d)
_h_stable() { printf 'same\n' >"$1/out.txt"; }
assert_idempotent "stable writer is idempotent" "$_h_state" _h_stable "$_h_state"
rm -rf "$_h_state"

echo "Test: assert_idempotent fails for a command that appends"
# The helper is worthless if it cannot detect the thing it exists to detect.
# Run it against a known-appending command, measure the increment it makes to
# FAIL, then restore both counters so this suite's own tally is unaffected.
# Restoring in place rather than running the helper in a `$(...)` subshell: the
# subshell would isolate the counters just as well, but every later reference to
# PASS/FAIL in this file then reads as SC2031 "modified in a subshell, that
# change might be lost" — a warning about the suite's real tally, raised by a
# test that has nothing to do with it.
_h_state=$(mktemp -d)
_h_appender() { printf 'more\n' >>"$1/log.txt"; }
_h_pass_before=$PASS
_h_fail_before=$FAIL
assert_idempotent "appending writer" "$_h_state" _h_appender "$_h_state" >/dev/null
_h_detected=$((FAIL - _h_fail_before))
PASS=$_h_pass_before
FAIL=$_h_fail_before
assert_equals "$_h_detected" "1" "assert_idempotent detects a non-idempotent command"
rm -rf "$_h_state"

echo "Test: assert_idempotent reports a non-zero run without taking the suite down"
# Both early returns fire when the helper has DETECTED something, which is the
# worst possible moment to abort the caller. Each used to end on a
# `[[ -n "$snap" ]] && rm -rf "$snap"` that is false on run 1, leaving status 1
# for the bare `return` to propagate; every suite runs under `set -e`, so a
# detected regression killed the run before it printed a Results line. Asserting
# the return status rather than relying on this suite surviving keeps the red
# signal readable — a helper that aborts would otherwise take this test with it.
_h_state=$(mktemp -d)
_h_outfile=$(mktemp)
_h_failer() {
	printf 'diagnostic from the failing run\n' >&2
	return 3
}
_h_pass_before=$PASS
_h_fail_before=$FAIL
_h_status=0
# shellcheck disable=SC2310 # suspending set -e here is the point: the status is
# captured into $_h_status and asserted on below. It is also the only way this
# test can report a regression rather than be killed by one — a helper that
# returns non-zero is precisely the defect under test.
assert_idempotent "non-zero exit" "$_h_state" _h_failer >"$_h_outfile" 2>&1 || _h_status=$?
_h_detected=$((FAIL - _h_fail_before))
PASS=$_h_pass_before
FAIL=$_h_fail_before
assert_equals "$_h_detected" "1" "a non-zero run counts exactly one failure"
assert_equals "$_h_status" "0" "the helper returns 0, so a set -e caller keeps running"
# The diagnostic is the whole reason the run failed. Discarding it leaves the
# reader a FAIL line naming a script and no way to tell why it exited non-zero.
_h_reported=$(cat "$_h_outfile")
if grep -qF 'diagnostic from the failing run' <<<"$_h_reported"; then
	echo "  PASS: the failing run's own output reaches the reader"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the failing run's output was discarded"
	FAIL=$((FAIL + 1))
fi
rm -rf "$_h_state" "$_h_outfile"

echo "Test: assert_idempotent reports a missing state path without taking the suite down"
_h_gone=$(mktemp -d)
_h_noop() { :; }
_h_pass_before=$PASS
_h_fail_before=$FAIL
_h_status=0
# shellcheck disable=SC2310 # status captured into $_h_status and asserted on;
# see the non-zero-exit case above.
assert_idempotent "missing state" "$_h_gone/never-written" _h_noop >/dev/null 2>&1 || _h_status=$?
_h_detected=$((FAIL - _h_fail_before))
PASS=$_h_pass_before
FAIL=$_h_fail_before
assert_equals "$_h_detected" "1" "a missing state path counts exactly one failure"
assert_equals "$_h_status" "0" "the missing-state path returns 0 too"
rm -rf "$_h_gone"

echo "Test: discard_fixture leaves the directory it is removing"
# The assertion is made against a freshly started shell rather than against
# `pwd`, which answers out of the shell's own cached value and so reports a
# directory that no longer exists. A new process has to ask the kernel, which is
# also what every script under test does — and what it gets is the whole point
# of the helper.
_h_fixture=$(mktemp -d)
_h_second=$(mktemp -d)
cd "$_h_fixture"
discard_fixture "$_h_fixture" "$_h_second"
_h_noise=$(bash -c ':' 2>&1)
assert_equals "$_h_noise" "" "a process started afterwards resolves its working directory"
if [[ -d "$_h_fixture" || -d "$_h_second" ]]; then
	echo "  FAIL: discard_fixture removed every path it was given"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: discard_fixture removed every path it was given"
	PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
