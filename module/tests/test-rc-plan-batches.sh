#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
PLAN="$SCRIPT_DIR/../skills/review-council/scripts/rc-plan-batches.sh"

# Byte-based delegation batching (issue #26). Batching used to trigger on file
# count while the resource it protects is context bytes, and it used to be prose
# in a phase file — so a run that skipped the decision was indistinguishable
# from one that never reached it.
#
# Two claims are under test everywhere below, and neither is worth much without
# the other: the split is a function of BYTES, and the split is always an
# ARTIFACT. A plan that batches correctly but writes nothing leaves the same
# hole the issue reported.
#
# Sessions are built by hand rather than by running rc-prepare.sh, as in
# test-rc-select-council.sh: the planner's contract is "given these artifacts,
# produce this plan", and a fixture that had to survive a git checkout and a
# forge probe to reach it would fail for reasons that say nothing about it.

# A prepared session carrying only the keys the planner reads.
plan_session() { # [effort]
	local dir
	dir=$(mktemp -d)
	{
		echo "# Review Council Session Tracking"
		echo ""
		echo "## Phase: Preparation"
		echo ""
		echo "- Effort: ${1:-standard}"
		echo ""
	} >"$dir/tracking.md"
	: >"$dir/changeset.txt"
	: >"$dir/diff.patch"
	printf '%s' "$dir"
}

# Append a changeset entry and a diff section for it of EXACTLY <bytes> bytes.
#
# The size is exact rather than approximate because every threshold assertion
# below is stated in bytes: a fixture that overshot its own budget by a header's
# worth would move a file between batches and the failure would read as a bug in
# the rule. The padding goes on the added line, which is where a real diff
# carries its bulk.
add_file() { # session path bytes
	local s="$1" p="$2" want="$3" header pad
	printf '%s\n' "$p" >>"$s/changeset.txt"
	header=$(printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -0,0 +1 @@\n+' "$p" "$p" "$p" "$p")
	# One byte of the budget belongs to the newline that closes the added line.
	pad=$((want - ${#header} - 1))
	[[ $pad -lt 0 ]] && pad=0
	{
		printf '%s' "$header"
		[[ $pad -gt 0 ]] && printf '%*s' "$pad" '' | tr ' ' 'x'
		printf '\n'
	} >>"$s/diff.patch"
}

# Add or replace a "- Key: value" line in a session's tracking.md, for the cases
# that configure a budget.
set_key() { # session key value
	local s="$1" key="$2" value="$3" tmp
	tmp=$(mktemp)
	grep -v -E "^- ${key}:" "$s/tracking.md" >"$tmp" || true
	printf -- '- %s: %s\n' "$key" "$value" >>"$tmp"
	mv "$tmp" "$s/tracking.md"
}

# Assert the number of batches in the written plan. Read from the artifact
# rather than from stdout: the artifact is what delegation dispatches, and a
# message that disagreed with it would be the more comfortable of the two to
# trust.
assert_batches() { # session expected label
	assert_jq "$1/batch-plan.json" '.batches | length' "$2" "$3"
}

echo "Test: a changeset under budget on bytes is one batch, whatever its file count"
# The issue's false positive: 25 files at 1.8 KB each — 45,000 bytes — used to
# batch because 25 > 20, while a changeset four times larger went whole.
d=$(plan_session)
for i in $(seq -w 1 25); do add_file "$d" "pkg/mod${i}.go" 1800; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "1" "25 files at 45,000 bytes stay in one batch"
assert_jq "$d/batch-plan.json" '.applied' "false" \
	"a single batch is recorded as not applied"
assert_jq "$d/batch-plan.json" '.context_bytes' "45000" \
	"context bytes are the size of the diff"
rm -rf "$d"

echo "Test: a changeset over budget on bytes is split, whatever its file count"
# The issue's false negative: 18 files at 10 KB each — 180,000 bytes — used to
# go to every persona in a single round because it touched seven fewer files
# than the threshold.
d=$(plan_session)
for i in $(seq -w 1 18); do add_file "$d" "pkg/mod${i}.go" 10000; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "2" "18 files at 180,000 bytes split into two batches"
assert_jq "$d/batch-plan.json" '.applied' "true" \
	"a split changeset is recorded as applied"
assert_jq "$d/batch-plan.json" '[.batches[].bytes] | all(. <= 131072)' "true" \
	"no batch exceeds the byte budget"
assert_jq "$d/batch-plan.json" '[.batches[].files[]] | length' "18" \
	"every changeset file appears exactly once across the batches"
rm -rf "$d"

echo "Test: the file cap closes a batch that bytes alone would leave open"
# Diff bytes do not price the reviewer's mandatory read of every file in its
# batch. 60 one-line files are 4 KB of diff and 60 whole files to open.
d=$(plan_session)
for i in $(seq -w 1 60); do add_file "$d" "pkg/f${i}.go" 70; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "2" "60 files split on the file cap, not on bytes"
assert_jq "$d/batch-plan.json" '[.batches[].files | length] | all(. <= 50)' "true" \
	"no batch exceeds the file cap"
rm -rf "$d"

echo "Test: files in one directory stay together when the whole group fits"
# A naive fill would top up batch 1 with the first file of b/ and straddle the
# boundary. Grouping by parent directory is what keeps a reviewer's context
# coherent.
d=$(plan_session)
set_key "$d" "Batch bytes" 40000
for i in 1 2 3; do add_file "$d" "a/f${i}.go" 10000; done
for i in 1 2 3; do add_file "$d" "b/f${i}.go" 10000; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "2" "two directories of 30,000 bytes each split in two"
assert_jq "$d/batch-plan.json" '[.batches[0].files[] | startswith("a/")] | all' "true" \
	"the first batch holds only the first directory"
assert_jq "$d/batch-plan.json" '[.batches[1].files[] | startswith("b/")] | all' "true" \
	"the second batch holds only the second directory"
rm -rf "$d"

echo "Test: a directory larger than the budget splits rather than overflowing"
d=$(plan_session)
set_key "$d" "Batch bytes" 25000
for i in 1 2 3 4; do add_file "$d" "big/f${i}.go" 10000; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "2" "one oversized directory splits across batches"
assert_jq "$d/batch-plan.json" '[.batches[].bytes] | all(. <= 25000)' "true" \
	"neither half of the split directory exceeds the budget"
rm -rf "$d"

echo "Test: a single file larger than the budget takes a batch of its own"
# A file cannot be split without handing a reviewer half a hunk, so the budget
# yields to it — but it does not drag a neighbour along.
d=$(plan_session)
set_key "$d" "Batch bytes" 40000
add_file "$d" "vendor/huge.go" 100000
add_file "$d" "pkg/small.go" 500
bash "$PLAN" "$d" >/dev/null
assert_jq "$d/batch-plan.json" \
	'[.batches[] | select(.files == ["vendor/huge.go"])] | length' "1" \
	"the oversized file is alone in its batch"
assert_jq "$d/batch-plan.json" '[.batches[].files[]] | length' "2" \
	"the oversized file is not split into pieces"
rm -rf "$d"

echo "Test: batch order does not depend on the order the changeset was written"
# Every local filesystem hands back creation order and CI's does not, so an
# order-dependent rule passes here and fails there.
d=$(plan_session)
set_key "$d" "Batch bytes" 40000
add_file "$d" "z/last.go" 10000
add_file "$d" "a/first.go" 10000
add_file "$d" "m/middle.go" 10000
bash "$PLAN" "$d" >/dev/null
assert_jq "$d/batch-plan.json" '.batches[0].files[0]' "a/first.go" \
	"planning sorts the changeset rather than trusting its order"
rm -rf "$d"

echo "Test: the byte budget and the file cap are configurable"
d=$(plan_session)
set_key "$d" "Batch bytes" 20000
set_key "$d" "Batch size" 2
for i in 1 2 3; do add_file "$d" "pkg/f${i}.go" 1000; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "2" "a configured file cap of 2 splits three files"
assert_jq "$d/batch-plan.json" '.byte_budget' "20000" \
	"the configured byte budget is recorded"
assert_jq "$d/batch-plan.json" '.file_cap' "2" \
	"the configured file cap is recorded"
rm -rf "$d"

echo "Test: an unusable configured value is reported and the default used"
# Dropped rather than clamped, as Max comments is: a typo that silently became 1
# would change what gets reviewed while reading as though it had been honoured.
d=$(plan_session)
set_key "$d" "Batch bytes" "lots"
add_file "$d" "pkg/f1.go" 1000
err=$(bash "$PLAN" "$d" 2>&1 >/dev/null)
assert_jq "$d/batch-plan.json" '.byte_budget' "131072" \
	"an unusable byte budget falls back to the default"
if [[ "$err" == *"Batch bytes"* ]]; then
	echo "  PASS: the ignored value is reported on stderr"
	PASS=$((PASS + 1))
else
	echo "  FAIL: the ignored value was dropped silently: ${err}"
	FAIL=$((FAIL + 1))
fi
rm -rf "$d"

echo "Test: deep mode plans each subsystem on its own"
# Deep dispatches per subsystem, so the budget applies within one, not across
# the changeset. Batch numbers restart per subsystem because a delegation round
# is identified by the pair.
d=$(plan_session deep)
set_key "$d" "Batch bytes" 15000
add_file "$d" "auth/a1.go" 10000
add_file "$d" "auth/a2.go" 10000
add_file "$d" "api/b1.go" 1000
jq -n '[{name: "auth", files: ["auth/a1.go", "auth/a2.go"]},
        {name: "api", files: ["api/b1.go"]}]' >"$d/subsystems.json"
bash "$PLAN" "$d" >/dev/null
assert_jq "$d/batch-plan.json" '[.batches[] | select(.subsystem == "auth")] | length' "2" \
	"the oversized subsystem is split in two"
assert_jq "$d/batch-plan.json" '[.batches[] | select(.subsystem == "api")] | length' "1" \
	"the small subsystem stays whole"
assert_jq "$d/batch-plan.json" '[.batches[] | select(.subsystem == "api") | .batch] | tostring' "[1]" \
	"batch numbering restarts within each subsystem"
rm -rf "$d"

echo "Test: diff sections for paths outside the changeset are disclosed, not charged"
d=$(plan_session)
add_file "$d" "pkg/kept.go" 1000
# A section whose path never reaches the changeset — a scope filter dropped it.
add_file "$d" "pkg/dropped.go" 2000
grep -v 'pkg/dropped.go' "$d/changeset.txt" >"$d/changeset.tmp"
mv "$d/changeset.tmp" "$d/changeset.txt"
bash "$PLAN" "$d" >/dev/null
assert_jq "$d/batch-plan.json" '.unattributed_bytes' "2000" \
	"bytes belonging to no changeset file are reported"
assert_jq "$d/batch-plan.json" '[.batches[].files[]] | join(",")' "pkg/kept.go" \
	"a path outside the changeset is not batched"
rm -rf "$d"

echo "Test: a changeset with no diff is bounded by the file cap alone"
# --scope all leaves diff.patch empty. Nothing measures bytes there, so the cap
# is the only thing standing between a reviewer and 120 files.
d=$(plan_session)
for i in $(seq -w 1 120); do printf 'pkg/f%s.go\n' "$i" >>"$d/changeset.txt"; done
bash "$PLAN" "$d" >/dev/null
assert_batches "$d" "3" "120 files with no diff split on the cap"
assert_jq "$d/batch-plan.json" '.context_bytes' "0" \
	"an empty diff measures zero context bytes"
rm -rf "$d"

echo "Test: the decision is an artifact even when nothing is split"
# The traceability half of the issue. A skipped decision and a decision never
# reached used to look identical after the fact.
d=$(plan_session)
add_file "$d" "pkg/one.go" 500
bash "$PLAN" "$d" >/dev/null
for artifact in batch-plan.json batches.txt; do
	if [[ -s "$d/$artifact" ]]; then
		echo "  PASS: ${artifact} is written for a single-batch run"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: ${artifact} missing after a single-batch run"
		FAIL=$((FAIL + 1))
	fi
done
assert_track "$d" "Batching" "not applied" "tracking records that nothing was split"
assert_track "$d" "Context bytes" "500" "tracking records the measurement"
assert_track "$d" "Byte budget" "131072" "tracking records the budget it was judged against"
assert_track "$d" "File cap" "50" "tracking records the secondary cap"
assert_track "$d" "Batches" "1" "tracking records the batch count"
rm -rf "$d"

echo "Test: batches.txt lists which files went into which batch"
d=$(plan_session)
set_key "$d" "Batch bytes" 15000
add_file "$d" "a/one.go" 10000
add_file "$d" "b/two.go" 10000
bash "$PLAN" "$d" >/dev/null
headings=$(grep -c '^## Batch ' "$d/batches.txt")
assert_equals "$headings" "2" "batches.txt carries one heading per batch"
listed=$(grep -c '^a/one.go$' "$d/batches.txt")
assert_equals "$listed" "1" "batches.txt lists each file once"
rm -rf "$d"

echo "Test: an empty changeset plans nothing and says so"
d=$(plan_session)
out=$(bash "$PLAN" "$d")
assert_jq_str "$out" '.status' "ok" "an empty changeset is not an error"
assert_jq "$d/batch-plan.json" '.batches | length' "0" \
	"an empty changeset yields no batches"
assert_jq "$d/batch-plan.json" '.applied' "false" \
	"an empty changeset is recorded as not applied"
rm -rf "$d"

echo "Test: a session missing its changeset degrades instead of aborting"
d=$(plan_session)
rm "$d/changeset.txt"
out=$(bash "$PLAN" "$d")
assert_jq_str "$out" '.status' "nothing_to_do" \
	"a session without a changeset reports nothing to do"
rm -rf "$d"

echo "Test: a session directory that does not exist degrades instead of aborting"
out=$(bash "$PLAN" "/nonexistent/session-$$")
assert_jq_str "$out" '.status' "nothing_to_do" \
	"a missing session directory reports nothing to do"

echo "Test: the payload carries the plan so the orchestrator need not re-read it"
d=$(plan_session)
for i in $(seq -w 1 18); do add_file "$d" "pkg/mod${i}.go" 10000; done
out=$(bash "$PLAN" "$d")
assert_jq_str "$out" '.status' "ok" "a planned split reports ok"
assert_jq_str "$out" '.batches | length' "2" "the payload carries the batches themselves"
assert_jq_str "$out" '.context_bytes' "180000" "the payload carries the measurement"
rm -rf "$d"

echo "Test: re-planning a session is a no-op"
# SKILL.md Step 2 resumes a prepared session, so every decision script runs
# again on re-entry. A tracking block appended twice would publish two answers.
d=$(plan_session)
set_key "$d" "Batch bytes" 15000
add_file "$d" "a/one.go" 10000
add_file "$d" "b/two.go" 10000
bash "$PLAN" "$d" >/dev/null
assert_idempotent "re-planning leaves the session unchanged" "$d" \
	bash "$PLAN" "$d"
blocks=$(grep -c '^## Phase: Batch Plan$' "$d/tracking.md")
assert_equals "$blocks" "1" "the tracking block is replaced, not appended"
rm -rf "$d"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
