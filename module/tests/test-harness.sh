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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
