#!/usr/bin/env bash
# Guards the mutation harness in .taskfiles/scripts/mutate-check.sh.
#
# The harness is the thing that decides whether every other suite is worth
# trusting, so a defect in it is quiet by construction: it reports on the suites
# rather than on itself, and a wrong answer reads exactly like a real hole.
#
# It used to copy the live `module/` tree once per mutation — 44 reads of a
# directory that anything else may be writing. A file edited between two
# mutations meant they ran against different source, and one caught mid-write
# meant a mutation applied to a half-written script. Both surface as MISSED or
# BROKEN against code that is in fact guarded, which sends whoever reads the
# report hunting a hole that does not exist. That happened: a concurrent edit
# produced a false MISSED and a count that could not be reconciled.
#
# The tree is now copied once and every mutation is taken from that snapshot.
# These tests pin that, by changing the live tree between two identical calls
# and asserting the second is unaffected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/../../.taskfiles/scripts/mutate-check.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$HARNESS" ]] || {
	echo "ERROR: mutation harness not found: $HARNESS" >&2
	exit 1
}

# Build a module tree shaped like the real one, with a single script to mutate
# and a single suite to run against it. The suite fails when it sees the
# mutated token, which is what makes a correctly applied mutation report
# `caught`.
make_fake_module() { # dest
	local dest="$1"
	mkdir -p "$dest/module/skills/review-council/scripts" "$dest/module/tests"
	printf '#!/usr/bin/env bash\nverdict="GOOD"\n' \
		>"$dest/module/skills/review-council/scripts/probe.sh"
	# One `  FAIL:` line on the failing path: the harness reads a non-zero exit
	# with no failed assertion as BROKEN rather than as a catch, so a suite that
	# merely exits 1 would not exercise the path under test here.
	cat >"$dest/module/tests/probe-suite.sh" <<-'SUITE'
		#!/usr/bin/env bash
		set -uo pipefail
		here="$(cd "$(dirname "$0")" && pwd)"
		if grep -q 'BAD' "$here/../skills/review-council/scripts/probe.sh"; then
			echo "  FAIL: the probe carries the mutated verdict"
			exit 1
		fi
		exit 0
	SUITE
}

# The harness detects that it is being sourced and defines check_mutation
# without running its own 44 mutations. `set -e` is restored afterwards because
# the harness sets `-uo pipefail` on load, which drops it.
#
# Deliberately not given a `source=` directive. Following the harness makes the
# linter read its sourced-copy guard as an unconditional `return` and report
# every line below this one as unreachable (SC2317), which is only ever true of
# the executed copy. SC1090 covers the unfollowed path instead.
# shellcheck disable=SC1090
source "$HARNESS"
set -euo pipefail

declare -F check_mutation >/dev/null
assert_equals "$?" "0" "sourcing the harness defines check_mutation and runs nothing"

fake=$(mktemp -d)
make_fake_module "$fake"
# Read by the sourced harness, not by anything in this file, which is why the
# linter cannot see a use for it.
# shellcheck disable=SC2034
root="$fake"

echo ""
echo "Test: a mutation is taken from the snapshot, not from the tree as it stands"

# Redirect to a file rather than capturing with `$(...)`: command substitution
# runs in a subshell, so the memoised snapshot path would be discarded after
# every call and each one would re-read the live tree. The harness itself calls
# check_mutation directly, in one shell, which is the behaviour under test.
out=$(mktemp)

check_mutation "probe" "probe.sh" 's/GOOD/BAD/' "probe-suite.sh" >"$out"
read -r report <"$out"
assert_equals "${report%% *}" "caught" "the first mutation applies and the suite goes red"

# Stand in for a concurrent write: the token the mutation matches on is gone.
# Read live, the next identical call reports BROKEN, because the expression no
# longer matches anything. Read from the snapshot, it is unchanged.
printf '#!/usr/bin/env bash\nverdict="REWRITTEN"\n' \
	>"$fake/module/skills/review-council/scripts/probe.sh"

check_mutation "probe" "probe.sh" 's/GOOD/BAD/' "probe-suite.sh" >"$out"
read -r report <"$out"
assert_equals "${report%% *}" "caught" "a tree rewritten mid-run does not change the verdict"

echo ""
echo "Test: a file added after the snapshot is not picked up mid-run"

# The snapshot is taken once, so the tree the mutations run against is the one
# that existed when the run started. Pinning this states which of the two
# possible answers the harness gives, rather than leaving it to whichever
# mutation happens to run first.
printf 'appeared later\n' >"$fake/module/late.txt"
check_mutation "probe" "probe.sh" 's/GOOD/BAD/' "probe-suite.sh" >"$out"
read -r report <"$out"
assert_equals "${report%% *}" "caught" "the run continues against the snapshot it started with"

# The harness only arms its own EXIT trap when executed, so a sourced copy
# leaves its snapshot for the caller to remove.
rm -rf "$fake" "$out" "${snapshot:?snapshot was never taken}"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
