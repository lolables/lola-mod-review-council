#!/usr/bin/env bash
# Session cache growth.
#
# Clones have been capped since rc-clone-target.sh gained its LRU
# (REVIEW_COUNCIL_CLONE_CACHE_MAX, default 10). Sessions had no cap at all:
# every review ever run left a directory behind for good, and so did every run
# that produced nothing — a prepare that exits `empty` still creates the
# session before the changeset scan decides there is nothing to review. Under
# per-PR CI use that is unbounded growth in a cache directory nobody looks at.
#
# The cap mirrors the clone LRU deliberately: same env-var shape, same POSIX
# `ls -dt` ordering, same "never evict what was just created" rule. Two
# different eviction disciplines in one cache directory would be two things to
# learn and two things to get wrong.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../skills/review-council/scripts/rc-prepare.sh"
AGENTS="$SCRIPT_DIR/../agents"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"

DEFAULT_CAP=20

# A local repo with a reviewable changeset and no origin, so preparation stays
# on the local path and makes no forge calls.
make_repo() {
	local work
	work=$(mktemp -d)
	setup_repo "$work" feature-head ""
	printf '%s' "$work"
}

# Run prepare in <work> and print the session_dir it created.
prepare_in() {
	local work="$1" cache="$2" result
	shift 2
	result=$(cd "$work" && AGENTS_DIR="$AGENTS" XDG_CACHE_HOME="$cache" \
		env "$@" bash "$SCRIPT" --mode code --scope changed 2>/dev/null)
	jq -r '.session_dir // empty' <<<"$result"
}

# Seed <n> session directories that look older than anything prepare creates.
# `touch -t CCYYMMDDhhmm` is the POSIX form; BSD touch rejects the free-form
# `-d` spellings, and this cap has to hold on macOS too.
seed_sessions() {
	local project_dir="$1" n="$2" i stamp
	for ((i = 0; i < n; i++)); do
		# Distinct, strictly ascending minutes well in the past, so `ls -dt`
		# orders them deterministically rather than by filesystem timing.
		printf -v stamp '2020010100%02d' "$i"
		mkdir -p "${project_dir}/seed-${i}/verdicts/_meta"
		touch -t "$stamp" "${project_dir}/seed-${i}"
	done
}

count_sessions() { find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

# Assigns before asserting: a command substitution nested inside another
# command has its exit status discarded, so a failing find would silently
# assert against the empty string instead of aborting the suite.
assert_session_count() {
	local dir="$1" expected="$2" label="$3" actual
	actual=$(count_sessions "$dir")
	assert_equals "$actual" "$expected" "$label"
}

echo "Test 1: the session cache is capped by default"
work=$(make_repo)
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 25
session2=$(prepare_in "$work" "$cache")
assert_session_count "$project_dir" "$DEFAULT_CAP" "cache pruned to the default cap"
if [[ -d "$session2" ]]; then
	echo "  PASS: the session just created survives the prune"
	PASS=$((PASS + 1))
else
	echo "  FAIL: prepare pruned the session it had just created"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$cache"

echo "Test 2: the oldest sessions are the ones evicted"
work=$(make_repo)
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 5
session2=$(prepare_in "$work" "$cache" REVIEW_COUNCIL_SESSION_CACHE_MAX=3)
assert_session_count "$project_dir" "3" "cache pruned to an explicit cap"
if [[ ! -d "$project_dir/seed-0" ]] && [[ -d "$project_dir/seed-4" ]]; then
	echo "  PASS: eviction is oldest-first"
	PASS=$((PASS + 1))
else
	echo "  FAIL: eviction did not follow mtime order"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$cache"

echo "Test 3: a cap of 1 keeps only the run in progress"
# The degenerate case has to leave a usable session behind: pruning the
# directory prepare is about to hand the orchestrator would break the run it
# belongs to.
work=$(make_repo)
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 6
session2=$(prepare_in "$work" "$cache" REVIEW_COUNCIL_SESSION_CACHE_MAX=1)
assert_session_count "$project_dir" "1" "only one session survives"
if [[ -d "$session2" ]] && [[ -f "$session2/tracking.md" ]]; then
	echo "  PASS: the surviving session is the usable one"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the surviving session is not the one prepare returned"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$cache"

echo "Test 4: a non-numeric cap falls back to the default"
# Same rule the clone LRU applies. A typo must not disable the cap silently,
# and must not delete everything either.
work=$(make_repo)
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 25
prepare_in "$work" "$cache" REVIEW_COUNCIL_SESSION_CACHE_MAX=lots >/dev/null
assert_session_count "$project_dir" "$DEFAULT_CAP" "non-numeric cap falls back"
rm -rf "$work" "$cache"

echo "Test 5: pruning stays inside one project"
work_a=$(make_repo)
work_b=$(make_repo)
cache=$(mktemp -d)
session_a=$(prepare_in "$work_a" "$cache")
session_b=$(prepare_in "$work_b" "$cache")
project_a=$(dirname "$session_a")
project_b=$(dirname "$session_b")
seed_sessions "$project_b" 4
seed_sessions "$project_a" 6
prepare_in "$work_a" "$cache" REVIEW_COUNCIL_SESSION_CACHE_MAX=1 >/dev/null
assert_session_count "$project_a" "1" "the reviewed project is pruned"
assert_session_count "$project_b" "5" "another project is left alone"
rm -rf "$work_a" "$work_b" "$cache"

echo "Test 6: a cache under the cap is left untouched"
# Asserted by survival rather than by a count. Two prepares a fraction of a
# second apart share one run id — `date +%Y%m%d-%H%M%S` has second granularity
# and `mkdir -p` accepts an existing directory — so the total after the second
# run is 4 or 5 depending on which side of a second boundary it lands. What
# must hold either way is that no existing session was evicted.
work=$(make_repo)
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 3
prepare_in "$work" "$cache" >/dev/null
survivors=0
for ((i = 0; i < 3; i++)); do [[ -d "$project_dir/seed-${i}" ]] && survivors=$((survivors + 1)); done
assert_equals "$survivors" "3" "no seeded session evicted below the cap"
if [[ -d "$session" ]]; then
	echo "  PASS: the earlier session survives below the cap"
	PASS=$((PASS + 1))
else
	echo "  FAIL: an earlier session was evicted below the cap"
	FAIL=$((FAIL + 1))
fi
rm -rf "$work" "$cache"

echo "Test 7: an empty review still prunes"
# A prepare that exits `empty` creates the session before the changeset scan
# runs, so no-op runs are exactly what accumulates. They must be capped too.
work=$(mktemp -d)
setup_repo "$work" feature-head ""
cache=$(mktemp -d)
session=$(prepare_in "$work" "$cache")
project_dir=$(dirname "$session")
seed_sessions "$project_dir" 6
# main..main is a resolvable but empty range: prepare creates the session, then
# reports `empty`.
(cd "$work" && AGENTS_DIR="$AGENTS" XDG_CACHE_HOME="$cache" \
	REVIEW_COUNCIL_SESSION_CACHE_MAX=2 bash "$SCRIPT" \
	--mode code --scope range --scope-value main..main >/dev/null 2>&1) || true
assert_session_count "$project_dir" "2" "an empty run prunes like any other"
rm -rf "$work" "$cache"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
