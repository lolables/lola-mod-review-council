#!/usr/bin/env bash
# Guards the suite selection used by .taskfiles/scripts/run-degraded-tests.sh.
#
# The degraded layer hides one optional tool from PATH and re-runs the suites,
# so that a fallback branch — which on any given host is either always taken or
# never taken — gets deliberately exercised. It used to re-run all of them for
# each tool, which is correct but is three full unit passes; most suites never
# reach a line that consults the tool at all.
#
# Narrowing it is only safe if the narrowing cannot silently drop a suite that
# did exercise a fallback. That is the same failure the layer exists to catch —
# the jq fallback validator shipped accepting "HIG" as a severity precisely
# because nothing ran it — so a selection bug here would disarm the guard while
# leaving it looking green. These tests pin the selection against a fixture
# tree of known shape rather than against the real module, so they assert the
# rule rather than restating whatever the repo happens to contain today.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELECTOR="$SCRIPT_DIR/../../.taskfiles/scripts/degraded-suites.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

[[ -f "$SELECTOR" ]] || {
	echo "ERROR: selector not found: $SELECTOR" >&2
	exit 1
}

# shellcheck source=/dev/null
source "$SELECTOR"
set -euo pipefail

# A module tree shaped like the real one, carrying one instance of every case
# the selection has to tell apart. Built once and reused: nothing below mutates
# it.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
scripts="$fixture/module/skills/review-council/scripts"
suites="$fixture/module/tests"
mkdir -p "$scripts/lib" "$suites"

# Invokes the tool on a live line — the unambiguous in-scope case.
cat >"$scripts/rc-direct.sh" <<-'EOF'
	#!/usr/bin/env bash
	gh pr view "$1" --json title
EOF

# Names the tool only in a full-line comment. This is the case the whole
# narrowing turns on: rc-lib.sh is sourced by ten of the thirteen scripts and
# discusses `gh` at length without ever calling it, so treating a comment as an
# invocation would pull nearly every suite back in and save nothing.
cat >"$scripts/rc-commented.sh" <<-'EOF'
	#!/usr/bin/env bash
	# Callers that have gh available get a richer path; see forge-adapters.md.
	# We deliberately do not shell out to gh from here.
	printf 'no forge calls\n'
EOF

# Reaches the tool through a sourced library rather than directly.
cat >"$scripts/rc-vialib.sh" <<-'EOF'
	#!/usr/bin/env bash
	source "$(dirname "$0")/lib/helper.sh"
EOF
cat >"$scripts/lib/helper.sh" <<-'EOF'
	#!/usr/bin/env bash
	fetch_mr() { glab mr view "$1" --output json; }
EOF

# Names the tool in a trailing comment. Distinguishing this from a real call
# means deciding where a `#` ends code and begins prose, which is not decidable
# by grep — inside a string or a parameter expansion it is neither. The
# selection is expected to read it as an invocation and include the suite: an
# extra suite costs seconds, a missing one costs the guarantee.
cat >"$scripts/rc-trailing.sh" <<-'EOF'
	#!/usr/bin/env bash
	printf 'plain\n' # the gh path lands here later
EOF

for s in direct commented vialib trailing; do
	cat >"$suites/test-$s.sh" <<-EOF
		#!/usr/bin/env bash
		bash "\$SCRIPT_DIR/../skills/review-council/scripts/rc-$s.sh"
	EOF
done

# Exercises no module script at all — the harness's own tests are like this.
cat >"$suites/test-standalone.sh" <<-'EOF'
	#!/usr/bin/env bash
	printf 'self-contained\n'
EOF

# Names the tool near the top and carries enough content after it to overrun a
# pipe buffer. That geometry is the whole point of this fixture.
#
# Reading a file as `sed ... | grep -q` under `set -o pipefail` reports a match
# as a miss: grep exits the moment it matches, sed is still writing, sed takes
# SIGPIPE, and pipefail returns the pipeline's status as 141. It only bites
# when sed cannot fit its whole output into the pipe buffer before grep leaves
# — under 64KiB it usually completes and the bug is invisible, which is how it
# survived a first round of tests here at 400 lines. On the real tree
# rc-extract-verdict.sh missed roughly four runs in five.
#
# 2000 lines is ~115KiB, comfortably past the 64KiB buffer, and misses 20 out
# of 20 against the defective form. Do not shrink this fixture to tidy it: at
# 400 lines it silently stops testing anything.
{
	printf '#!/usr/bin/env bash\n'
	printf 'command -v gh >/dev/null 2>&1 || return 0\n'
	for i in $(seq 1 2000); do
		printf 'placeholder_%04d="padding so the reader is still writing"\n' "$i"
	done
} >"$scripts/rc-bulky.sh"
cat >"$suites/test-bulky.sh" <<-'EOF'
	#!/usr/bin/env bash
	bash "$SCRIPT_DIR/../skills/review-council/scripts/rc-bulky.sh"
EOF

# A shared helper that every suite sources and that mentions a tool-using
# script in prose, without ever running it. This is the shape that collapsed
# the first version of the selection: module/tests/helpers.sh discusses
# rc-extract-verdict.sh in a comment at line 182, all 40 suites source
# helpers.sh, and so every suite came out connected to every tool. The answer
# was still "safe" — it never dropped a suite — but a selection that always
# returns everything saves nothing and hides that it has stopped discriminating.
cat >"$suites/fixture-helpers.sh" <<-'EOF'
	#!/usr/bin/env bash
	# rc-direct.sh is asserted on separately, because the forge call it makes
	# is not observable from here.
	shared_helper() { printf 'shared\n'; }
EOF
cat >"$suites/test-proseonly.sh" <<-'EOF'
	#!/usr/bin/env bash
	source "$SCRIPT_DIR/fixture-helpers.sh"
	shared_helper
EOF

# Emits the tool's name as data — a template line, not a command. This is the
# other half of what collapsed the gh selection: helpers.sh writes a fixture
# report containing the line "- Tooling: gh" at line 378, on a live line rather
# than in a comment, so stripping comments does not reach it. Hiding gh from
# PATH cannot change what this prints.
cat >"$scripts/rc-template.sh" <<-'EOF'
	#!/usr/bin/env bash
	cat <<-REPORT
	## Phase: Preparation
	- Tooling: gh
	- Mode: code
	REPORT
EOF
cat >"$suites/test-template.sh" <<-'EOF'
	#!/usr/bin/env bash
	bash "$SCRIPT_DIR/../skills/review-council/scripts/rc-template.sh"
EOF

# Calls the tool through a variable rather than by name. Requiring the tool to
# sit in command position is a narrowing, and this is the case it could
# plausibly narrow past — so it is pinned rather than assumed. prepare-repo.sh
# does exactly this (`forge_tool="gh"`, invoked later as "$forge_tool").
cat >"$scripts/rc-indirect.sh" <<-'EOF'
	#!/usr/bin/env bash
	forge_tool="glab"
	"$forge_tool" mr view "$1"
EOF
cat >"$suites/test-indirect.sh" <<-'EOF'
	#!/usr/bin/env bash
	bash "$SCRIPT_DIR/../skills/review-council/scripts/rc-indirect.sh"
EOF

# Driven code that does not live under module/. test-review-open-prs.sh
# exercises scripts/review-open-prs.sh at the repo root, which calls `gh`
# twelve times including `gh auth status`; a walk rooted at module/ cannot see
# it, and the suite dropped out of the gh selection while looking correct.
# Suites still only ever come from module/tests — it is the code they drive
# that is spread across trees.
mkdir -p "$fixture/scripts"
cat >"$fixture/scripts/driver.sh" <<-'EOF'
	#!/usr/bin/env bash
	gh auth status >/dev/null 2>&1 || exit 1
EOF
cat >"$suites/test-driver.sh" <<-'EOF'
	#!/usr/bin/env bash
	bash "$SCRIPT_DIR/../../scripts/driver.sh"
EOF

# How many times <suite> appears in <tool>'s selection: 1 when selected, 0 when
# not. Compared on the basename so the fixture's temp path never reaches an
# expectation, and matched with awk on the exact final path component rather
# than with a regex, where the dot in "test-direct.sh" would match any
# character.
#
# Each step is a plain assignment rather than one nested pipeline inlined into
# the assertion's argument. A function invoked inside a command substitution
# that is itself an argument has its exit status discarded (SC2310/SC2312), so
# a selector that died mid-run would yield an empty string and be read as
# "suite correctly absent" — a passing test for a broken selection, which is
# the one result this file must never produce.
selection_count() { # tool suite-basename -> 0 or 1
	local out n
	out=$(suites_touching_tool "$1" "$fixture")
	n=$(awk -F/ -v want="$2" '$NF == want { c++ } END { print c + 0 }' <<<"$out")
	printf '%s' "$n"
}

# ---------------------------------------------------------------------------
echo "Test 1: a suite whose script invokes the tool is selected"
actual=$(selection_count gh test-direct.sh)
assert_equals "$actual" "1" \
	"test-direct.sh is in the gh selection"

echo "Test 2: a suite whose script only names the tool in a comment is dropped"
# The saving lives here. If this regresses, the layer silently goes back to
# three full unit passes and nothing fails — so assert the absence directly.
actual=$(selection_count gh test-commented.sh)
assert_equals "$actual" "0" \
	"test-commented.sh is absent from the gh selection"

echo "Test 3: a suite reaching the tool through a sourced library is selected"
actual=$(selection_count glab test-vialib.sh)
assert_equals "$actual" "1" \
	"test-vialib.sh is in the glab selection, via lib/helper.sh"

echo "Test 4: a trailing-comment mention is read as an invocation, not prose"
actual=$(selection_count gh test-trailing.sh)
assert_equals "$actual" "1" \
	"test-trailing.sh is in the gh selection"

echo "Test 5: a suite that exercises no module script is never selected"
actual=$(selection_count gh test-standalone.sh)
assert_equals "$actual" "0" \
	"test-standalone.sh is absent from the gh selection"

echo "Test 6: the two tools select different suites"
# A selection that ignored its argument and returned everything would pass
# tests 1, 3 and 4 on its own.
actual=$(selection_count glab test-direct.sh)
assert_equals "$actual" "0" \
	"the gh-only suite is absent from the glab selection"

echo "Test 7: detection does not depend on how fast the reader drains"
# Repeated rather than run once: the defect this pins is a race, so a single
# call reproduces it only most of the time and a one-shot assertion would be a
# flaky test — worse than none, because a flaky red gets re-run until green.
# Ten identical calls put a false green below one in a million at the observed
# rate, and cost ten greps over a 2000-line fixture when the code is correct.
misses=0
for _ in $(seq 1 10); do
	hits=$(selection_count gh test-bulky.sh)
	[[ "$hits" == "1" ]] || misses=$((misses + 1))
done
assert_equals "$misses" "0" "test-bulky.sh is selected on all 10 runs"

echo "Test 8: a prose cross-reference in a shared helper does not propagate"
# The counterpart to Test 2, one level up: naming a script in a comment is not
# a dependency on it, exactly as naming a tool in a comment is not a call to
# it. Without this the graph closes over every suite that sources a common
# helper, which here is all of them.
actual=$(selection_count gh test-proseonly.sh)
assert_equals "$actual" "0" \
	"test-proseonly.sh is absent from the gh selection"

echo "Test 9: the tool's name as data is not an invocation"
actual=$(selection_count gh test-template.sh)
assert_equals "$actual" "0" \
	"test-template.sh is absent from the gh selection"

echo "Test 10: a tool invoked through a variable is still selected"
# The narrowing in Test 9 must not cost this. If command position were the only
# accepted form, this suite would drop out silently.
actual=$(selection_count glab test-indirect.sh)
assert_equals "$actual" "1" \
	"test-indirect.sh is in the glab selection"

echo "Test 11: a suite driving a script outside module/ is selected"
actual=$(selection_count gh test-driver.sh)
assert_equals "$actual" "1" \
	"test-driver.sh is in the gh selection, via scripts/driver.sh"

echo "Test 12: a tool that matches nothing is an error, not an empty selection"
# An empty selection has two causes and they are indistinguishable from the
# outside: the tool name is wrong, or the reference walk broke. Both mean the
# run proves nothing, and both would otherwise print green having executed no
# suite at all — the precise shape of failure this layer exists to prevent.
# Reported by return status, not `exit`, so that a caller sourcing this file
# keeps control.
set +e
err=$(suites_touching_tool no-such-tool "$fixture" 2>&1 >/dev/null)
status=$?
set -e
assert_equals "$status" "1" "an unmatched tool returns non-zero"
if grep -q 'no-such-tool' <<<"$err"; then
	echo "  PASS: the error names the tool that matched nothing"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the error does not name the tool; got '$err'"
	FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
