#!/usr/bin/env bash
# Run module unit suites and report a combined total.
#
# Usage: run-unit-tests.sh [suite.sh ...]
#
# With no arguments every suite is discovered from module/tests. The list used
# to be hand-maintained in Taskfile.yml, and a new test file that nobody
# remembered to add simply never ran — silently, and indistinguishably from
# passing. Discovery removes that failure mode and is what `task test:unit`
# uses.
#
# With arguments, exactly the named suites run. The degraded layer uses this to
# run the narrowed selection from degraded-suites.sh rather than all 40 suites
# per hidden tool. A named suite that cannot be read is an error rather than a
# skip: a caller whose selection has gone wrong would otherwise run a smaller
# set than it asked for and still be told everything passed.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$root/module/tests"

suites=()
if [[ $# -gt 0 ]]; then
	for suite in "$@"; do
		if [[ ! -f "$suite" ]]; then
			echo "ERROR: no such suite: $suite" >&2
			exit 1
		fi
		suites+=("$suite")
	done
else
	# Glob-sorted for a stable, reproducible order across filesystems: the
	# readdir order a local disk returns is not the one CI returns.
	for suite in "$test_dir"/test-*.sh; do
		[[ -f "$suite" ]] || continue
		suites+=("$suite")
	done
	if [[ ${#suites[@]} -eq 0 ]]; then
		# Discovery finding nothing means the tree moved or the glob broke, not
		# that there is nothing to test. Reporting "0 failed" would be true and
		# entirely misleading.
		echo "ERROR: no suites discovered under $test_dir." >&2
		exit 1
	fi
fi

failed_suites=()
assertion_failures=()
deleted_cwd=()
total_pass=0
total_fail=0

for suite in "${suites[@]}"; do
	name="$(basename "$suite")"
	output=$(bash "$suite" 2>&1)
	status=$?
	echo "$output"

	# A suite that removes the directory it is standing in keeps an
	# unresolvable working directory until its next `cd`, and every process it
	# starts in that window inherits one. The shells among them say so on
	# stderr; nothing else does. That makes this the only visible edge of a
	# condition that is otherwise silent — `getcwd` failing inside a script
	# under test surfaces as whatever that script does next, not as this
	# message — so the message is treated as the failure it points at rather
	# than as noise to scroll past.
	if grep -q 'error retrieving current directory' <<<"$output"; then
		deleted_cwd+=("$name")
	fi

	# Each suite ends with "Results: N passed, M failed".
	line=$(echo "$output" | grep -E '^Results: [0-9]+ passed, [0-9]+ failed$' | tail -1)
	if [[ -n "$line" ]]; then
		p=$(echo "$line" | sed -n 's/^Results: \([0-9]*\) passed.*/\1/p')
		f=$(echo "$line" | sed -n 's/.*passed, \([0-9]*\) failed$/\1/p')
		total_pass=$((total_pass + p))
		total_fail=$((total_fail + f))
		[[ $f -gt 0 ]] && assertion_failures+=("$name ($f)")
	elif [[ $status -eq 0 ]]; then
		# A suite that exits clean without a Results line has changed its
		# contract; counting it as a pass would hide that.
		echo "ERROR: $name exited 0 but printed no Results line" >&2
		failed_suites+=("$name (no Results line)")
		continue
	fi

	[[ $status -eq 0 ]] || failed_suites+=("$name")
done

# Counted from what actually ran, not from what the directory holds. Taken from
# the tree it would report 40 for a nine-suite degraded selection, which reads
# as full coverage.
suite_count=${#suites[@]}

echo ""
echo "========================================"
echo "Suites run:  $suite_count"
echo "Assertions:  $total_pass passed, $total_fail failed"
if [[ ${#failed_suites[@]} -gt 0 || ${#deleted_cwd[@]} -gt 0 || $total_fail -gt 0 ]]; then
	# A suite may report failed assertions and still exit 0 — a convention this
	# harness must not depend on. Either signal alone fails the run.
	#
	# The three are listed separately because they are not the same claim and do
	# not always name the same suite: a suite can exit non-zero having asserted
	# nothing (it died), a suite that changed convention can fail assertions
	# while exiting 0, and a suite that deletes its own working directory does
	# both of those things correctly and still leaves the run unsound. Folding
	# them into one list points the reader at whichever suite happens to be in
	# another bucket.
	if [[ ${#failed_suites[@]} -gt 0 ]]; then
		echo "Failed:      ${#failed_suites[@]} suite(s) exited non-zero"
		printf '  - %s\n' "${failed_suites[@]}"
	fi
	if [[ ${#assertion_failures[@]} -gt 0 ]]; then
		echo "Failed:      $total_fail assertion(s), by suite"
		printf '  - %s\n' "${assertion_failures[@]}"
	fi
	if [[ ${#deleted_cwd[@]} -gt 0 ]]; then
		echo "Failed:      ${#deleted_cwd[@]} suite(s) ran on a deleted working directory"
		printf '  - %s (cd out of a fixture before removing it)\n' "${deleted_cwd[@]}"
	fi
	echo "========================================"
	exit 1
fi
echo "========================================"
exit 0
