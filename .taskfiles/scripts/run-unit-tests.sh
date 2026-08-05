#!/usr/bin/env bash
# Discover and run every module unit suite, reporting a combined total.
#
# The suite list used to be hand-maintained in Taskfile.yml. A new test file
# that nobody remembered to add to that list simply never ran — silently, and
# indistinguishably from passing. Discovery removes the failure mode.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$root/module/tests"

failed_suites=()
assertion_failures=()
total_pass=0
total_fail=0

# Sorted for a stable, reproducible order across filesystems.
for suite in "$test_dir"/test-*.sh; do
	[[ -f "$suite" ]] || continue
	name="$(basename "$suite")"
	output=$(bash "$suite" 2>&1)
	status=$?
	echo "$output"

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

suite_count=$(find "$test_dir" -maxdepth 1 -name 'test-*.sh' | wc -l)
suite_count="${suite_count//[[:space:]]/}"

echo ""
echo "========================================"
echo "Suites run:  $suite_count"
echo "Assertions:  $total_pass passed, $total_fail failed"
if [[ ${#failed_suites[@]} -gt 0 || $total_fail -gt 0 ]]; then
	# A suite may report failed assertions and still exit 0 — a convention this
	# harness must not depend on. Either signal alone fails the run.
	#
	# The two are listed separately because they are not the same claim and do
	# not always name the same suite: a suite can exit non-zero having asserted
	# nothing (it died), and a suite that changed convention can fail assertions
	# while exiting 0. Folding them into one list points the reader at whichever
	# suite happens to be in the other bucket.
	if [[ ${#failed_suites[@]} -gt 0 ]]; then
		echo "Failed:      ${#failed_suites[@]} suite(s) exited non-zero"
		printf '  - %s\n' "${failed_suites[@]}"
	fi
	if [[ ${#assertion_failures[@]} -gt 0 ]]; then
		echo "Failed:      $total_fail assertion(s), by suite"
		printf '  - %s\n' "${assertion_failures[@]}"
	fi
	echo "========================================"
	exit 1
fi
echo "========================================"
exit 0
