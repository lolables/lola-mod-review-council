#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
BUILD="$SCRIPT_DIR/../skills/review-council/scripts/rc-build-context.sh"

# Issue #101: reviewers skipped the documents their agent files told them to
# read, and rarely opened the files under review. This script delivers both:
# a preamble pasted into every prompt, and one bundle of changed-file text per
# delegation round, passed by path. Sessions are built by hand, as in
# test-rc-plan-batches.sh: the contract is "given these artifacts, write these".

# A session with a review tree, a tracking.md carrying Language/Framework, and
# a one-batch plan over the given files. Prints the session dir; the review
# root is <session>/tree.
ctx_session() { # language framework file...
	local s lang="$1" fw="$2"
	shift 2
	s=$(mktemp -d)
	mkdir -p "$s/tree"
	printf -- '- Review root: %s\n' "$s/tree" >"$s/session.txt"
	printf '## Phase: Preparation\n\n- Language: %s\n- Framework: %s\n\n' "$lang" "$fw" >"$s/tracking.md"
	: >"$s/diff.patch"
	printf '%s\n' "$@" >"$s/changeset.txt"
	# On stdin, not --args: jq parses a file named like "-l" as an option.
	printf '%s\n' "$@" | jq -Rn '[inputs] as $files | {applied: false, byte_budget: 131072, file_cap: 50,
		batches: [{batch: 1, subsystem: null, files: $files, bytes: 0}]}' >"$s/batch-plan.json"
	printf '%s' "$s"
}

echo "Test: the preamble carries severity, the selected packs' calibration and the output format"
s=$(ctx_session go gin a.go)
printf 'package a\n' >"$s/tree/a.go"
bash "$BUILD" "$s" >/dev/null
p="$s/prompts/preamble.md"
sev_first="# Severity Convention Pack"
assert_match_count "$(<"$p")" "1" "severity.md body is included" -xF "$sev_first"
assert_match_count "$(<"$p")" "0" "severity.md front matter is stripped" -F "pack_id:"
assert_match_count "$(<"$p")" "1" "the Go pack's Calibration Notes are included" -xF "## Calibration Notes"
assert_match_count "$(<"$p")" "1" "the protocol's Output Format is included" -xF "## Output Format"
# fw-gin.md does not exist, so no framework pack is added.
assert_match_count "$(<"$p")" "0" "a framework without a pack adds nothing" -F "fw-gin.md"
order=$(grep -n -xF -e "$sev_first" -e "## Calibration Notes" -e "## Output Format" "$p" | cut -d: -f2- | tr '\n' '|')
assert_equals "$order" "${sev_first}|## Calibration Notes|## Output Format|" "fixed order: severity, packs, output format"
# The preamble is pasted verbatim with nothing substituted, so a `${...}`
# placeholder in a copied section would reach every reviewer as literal text.
# shellcheck disable=SC2016 # the literal two characters, not an expansion.
assert_match_count "$(<"$p")" "0" "no unexpanded placeholder" -F '${'
rm -rf "$s"

echo "Test: React brings its Severity Calibration section as well as its Calibration Notes"
s=$(ctx_session typescript react a.tsx)
printf 'export {}\n' >"$s/tree/a.tsx"
bash "$BUILD" "$s" >/dev/null
assert_match_count "$(<"$s/prompts/preamble.md")" "2" "TS and React Calibration Notes" -xF "## Calibration Notes"
assert_match_count "$(<"$s/prompts/preamble.md")" "1" "React Severity Calibration" -xF "## Severity Calibration"
rm -rf "$s"

echo "Test: an unknown language adds no pack (base.md has no calibration section)"
s=$(ctx_session unknown unknown a.txt)
printf 'x\n' >"$s/tree/a.txt"
bash "$BUILD" "$s" >/dev/null
assert_match_count "$(<"$s/prompts/preamble.md")" "0" "no Calibration Notes" -xF "## Calibration Notes"
rm -rf "$s"

echo "Test: the preamble is byte-identical across runs"
# #30: a stable prefix is what lets five dispatches share a prompt cache.
s=$(ctx_session go go-module a.go)
printf 'package a\n' >"$s/tree/a.go"
bash "$BUILD" "$s" >/dev/null
first=$(cksum <"$s/prompts/preamble.md")
bash "$BUILD" "$s" >/dev/null
second=$(cksum <"$s/prompts/preamble.md")
assert_equals "$second" "$first" "same bytes on a re-run"
rm -rf "$s"

echo "Test: a language value that is not a plain token selects no pack"
s=$(ctx_session "../../etc/go" unknown a.go)
printf 'package a\n' >"$s/tree/a.go"
bash "$BUILD" "$s" >/dev/null
assert_match_count "$(<"$s/prompts/preamble.md")" "0" "no pack read through a crafted Language" -xF "## Calibration Notes"
rm -rf "$s"

echo "Test: a shipped pack missing its Calibration Notes stops the build"
# A packaging defect must not ship a preamble that silently lacks the section.
fake=$(mktemp -d)
cp -R "$SCRIPT_DIR/../skills/review-council" "$fake/review-council"
sed '/^## Calibration Notes$/d' "$fake/review-council/references/lang-go.md" >"$fake/lang-go.md"
mv "$fake/lang-go.md" "$fake/review-council/references/lang-go.md"
s=$(ctx_session go go-module a.go)
printf 'package a\n' >"$s/tree/a.go"
rc=0
out=$(bash "$fake/review-council/scripts/rc-build-context.sh" "$s" 2>&1) || rc=$?
assert_equals "$rc" "1" "exits non-zero"
assert_match_count "$out" "1" "names the file and heading" -F "lang-go.md has no '## Calibration Notes' section"
rm -rf "$s" "$fake"

# Append a diff section for <path> whose new side is lines <start>..<end>.
add_hunk() { # session path start end
	local s="$1" p="$2" a="$3" b="$4" n
	n=$((b - a + 1))
	{
		printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -%d,%d +%d,%d @@\n' "$p" "$p" "$p" "$p" "$a" "$n" "$a" "$n"
		for ((i = a; i <= b; i++)); do printf '+line %d\n' "$i"; done
	} >>"$s/diff.patch"
}

echo "Test: one bundle per round, files inlined with line numbers, index written"
s=$(ctx_session go go-module a.go b.go)
seq 1 20 | sed 's/^/line /' >"$s/tree/a.go"
printf 'package b\n' >"$s/tree/b.go"
add_hunk "$s" a.go 5 8
out=$(bash "$BUILD" "$s")
assert_jq_str "$out" '.status' "ok" "status ok"
b="$s/prompts/batch1-context.md"
line12=$(printf '%6d\tline 12' 12)
assert_match_count "$(<"$b")" "1" "a.go line 12 is numbered" -xF "$line12"
assert_jq "$s/prompts/context.json" '.rounds[0].bundle' "prompts/batch1-context.md" "bundle path"
assert_jq "$s/prompts/context.json" '.rounds[0].verdict_dir' "" "single round writes unnested verdicts"
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].hunks | tojson' "[[5,8]]" "hunk range recorded"
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].outside' "true" "a.go has lines outside its hunk"
assert_jq "$s/prompts/context.json" '.rounds[0].gate' "required" "gate required"
assert_match_count "$(<"$s/tracking.md")" "1" "tracking block written" -x "## Phase: Context"
rm -rf "$s"

echo "Test: a file containing a fence cannot close the bundle's fence"
s=$(ctx_session go go-module a.go)
printf 'x\n````\n## Injected heading\n' >"$s/tree/a.go"
add_hunk "$s" a.go 1 1
bash "$BUILD" "$s" >/dev/null
fence=$(grep -m1 -E '^`{3,}$' "$s/prompts/batch1-context.md")
assert_equals "${#fence}" "5" "the fence is one backtick longer than the longest run"
rm -rf "$s"

echo "Test: files left out are listed under Read directly, each with its reason"
s=$(ctx_session go go-module big.go gone.go link.go bin.dat)
head -c 40000 /dev/zero | tr '\0' 'x' >"$s/tree/big.go"
ln -s /etc/passwd "$s/tree/link.go"
printf 'a\0b\n' >"$s/tree/bin.dat"
bash "$BUILD" "$s" >/dev/null
b="$s/prompts/batch1-context.md"
for want in "big.go\` — over cap" "gone.go\` — deleted" "link.go\` — symlink" "bin.dat\` — binary"; do
	assert_match_count "$(<"$b")" "1" "listed: $want" -F "$want"
done
assert_match_count "$(<"$b")" "0" "the symlink target is never read" -F "root:"
assert_jq "$s/prompts/context.json" '[.rounds[0].files[] | select(.inlined)] | length' "0" "nothing inlined"
rm -rf "$s"

echo "Test: a path escaping the review root is never read"
s=$(ctx_session go go-module ../secret.go)
printf 'TOPSECRET\n' >"$s/secret.go"
bash "$BUILD" "$s" >/dev/null
assert_match_count "$(<"$s/prompts/batch1-context.md")" "0" "content not inlined" -F "TOPSECRET"
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].reason' "outside root" "reason recorded"
rm -rf "$s"

echo "Test: the bundle stops at the plan's byte budget, first-fit in plan order"
s=$(ctx_session go go-module a.go b.go c.go)
jq '.byte_budget = 25000' "$s/batch-plan.json" >"$s/p" && mv "$s/p" "$s/batch-plan.json"
head -c 20000 /dev/zero | tr '\0' 'a' >"$s/tree/a.go"
head -c 10000 /dev/zero | tr '\0' 'b' >"$s/tree/b.go"
head -c 4000 /dev/zero | tr '\0' 'c' >"$s/tree/c.go"
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '[.rounds[0].files[] | "\(.path):\(.inlined)"] | join(",")' \
	"a.go:true,b.go:false,c.go:true" "b.go skipped as bundle full, the smaller c.go still fits"
assert_jq "$s/prompts/context.json" '.rounds[0].files[1].reason' "bundle full" "reason"
rm -rf "$s"

echo "Test: the gate is waived when no file has a line outside its hunks"
s=$(ctx_session go go-module new.go)
seq 1 3 >"$s/tree/new.go"
add_hunk "$s" new.go 1 3
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '.rounds[0].gate' "waived" "all-new file waives"
assert_match_count "$(<"$s/prompts/batch1-context.md")" "1" "the bundle says why" -F "No file in this round has a line outside the diff hunks, so context_check is not required"
rm -rf "$s"

echo "Test: an empty diff (--scope all) waives the gate"
s=$(ctx_session go go-module a.go)
seq 1 3 >"$s/tree/a.go"
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '.rounds[0].gate' "waived" "no diff, no hunks to be outside of"
assert_match_count "$(<"$s/prompts/batch1-context.md")" "1" "the bundle names the missing diff" -F "This round has no diff, so context_check is not required"
rm -rf "$s"

echo "Test: multi-round and deep-mode plans name bundles and verdict dirs like delegate.md"
s=$(ctx_session go go-module a.go b.go c.go)
printf 'x\n' >"$s/tree/a.go"
printf 'x\n' >"$s/tree/b.go"
printf 'x\n' >"$s/tree/c.go"
jq -n '{byte_budget: 131072, batches: [
	{batch: 1, subsystem: null, files: ["a.go"]}, {batch: 2, subsystem: null, files: ["b.go"]}]}' >"$s/batch-plan.json"
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '[.rounds[] | "\(.bundle)=\(.verdict_dir)"] | join(",")' \
	"prompts/batch1-context.md=batch1,prompts/batch2-context.md=batch2" "batched rounds nest"
jq -n '{byte_budget: 131072, batches: [
	{batch: 1, subsystem: "core", files: ["a.go"]}, {batch: 2, subsystem: "core", files: ["b.go"]},
	{batch: 1, subsystem: "cli", files: ["c.go"]}]}' >"$s/batch-plan.json"
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '[.rounds[] | "\(.bundle)=\(.verdict_dir)"] | join(",")' \
	"prompts/core/batch1-context.md=core/batch1,prompts/core/batch2-context.md=core/batch2,prompts/cli/batch1-context.md=cli" \
	"subsystem is the outer directory; a single-batch subsystem stays unnested"
rm -rf "$s"

echo "Test: a subsystem name that is not a safe path component stops the build"
s=$(ctx_session go go-module a.go)
printf 'x\n' >"$s/tree/a.go"
jq -n '{byte_budget: 131072, batches: [{batch: 1, subsystem: "../x", files: ["a.go"]}]}' >"$s/batch-plan.json"
rc=0
out=$(bash "$BUILD" "$s" 2>"$s/stderr") || rc=$?
assert_equals "$rc" "1" "exits non-zero"
assert_jq_str "$out" '.status' "error" "stdout is an error status"
assert_jq_str "$out" '.message | contains("\"../x\"")' "true" "names the subsystem"
rm -rf "$s"

echo "Test: a materialised review root outside the cwd is honoured"
s=$(ctx_session go go-module a.go)
printf 'package a // MARKER\n' >"$s/tree/a.go"
(cd / && bash "$BUILD" "$s" >/dev/null)
assert_match_count "$(<"$s/prompts/batch1-context.md")" "1" "read from the recorded root" -F "MARKER"
rm -rf "$s"

echo "Test: re-building a session is a no-op"
s=$(ctx_session go go-module a.go)
seq 1 9 >"$s/tree/a.go"
add_hunk "$s" a.go 2 3
bash "$BUILD" "$s" >/dev/null
assert_idempotent "re-building leaves the session unchanged" "$s" bash "$BUILD" "$s"
assert_match_count "$(<"$s/tracking.md")" "1" "one tracking block" -x "## Phase: Context"
rm -rf "$s"

echo "Test: a missing batch plan is an error, not a quiet skip"
s=$(ctx_session go go-module a.go)
rm "$s/batch-plan.json"
rc=0
out=$(bash "$BUILD" "$s") || rc=$?
assert_equals "$rc" "1" "exits 1"
assert_jq_str "$out" '.status' "error" "status error"
rm -rf "$s"

echo "Test: under review root '.', operand-shaped file names are read as files"
# A bare "a=b" is an awk assignment and a bare "-l" a cmp option; either used
# to drop or misfile files while the build still reported ok.
s=$(ctx_session go go-module a=b -l c.go)
printf -- '- Review root: .\n' >"$s/session.txt"
printf 'A_MARK\n' >"$s/tree/a=b"
printf 'L_MARK\n' >"$s/tree/-l"
printf 'C_MARK\n' >"$s/tree/c.go"
(cd "$s/tree" && bash "$BUILD" "$s" >/dev/null)
assert_jq "$s/prompts/context.json" '[.rounds[0].files[] | "\(.path):\(.inlined)"] | join(",")' \
	"a=b:true,-l:true,c.go:true" "all three inlined"
bundle_text=$(<"$s/prompts/batch1-context.md")
for mark in A_MARK L_MARK C_MARK; do
	assert_match_count "$bundle_text" "1" "$mark inlined" -F "$mark"
done
rm -rf "$s"

echo "Test: a directory symlink escaping the root is never read through"
s=$(ctx_session go go-module sub/secret.go)
away=$(mktemp -d)
printf 'DIR_SECRET\n' >"$away/secret.go"
ln -s "$away" "$s/tree/sub"
bash "$BUILD" "$s" >/dev/null
assert_match_count "$(<"$s/prompts/batch1-context.md")" "0" "content not inlined" -F "DIR_SECRET"
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].reason' "outside root" "reason recorded"
rm -rf "$s" "$away"

echo "Test: an empty file is inlined and has no line outside the hunks"
s=$(ctx_session go go-module empty.go other.go)
: >"$s/tree/empty.go"
seq 1 3 >"$s/tree/other.go"
add_hunk "$s" other.go 1 1
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '.rounds[0].files[0] | "\(.inlined):\(.outside)"' "true:false" "inlined, outside false"
rm -rf "$s"

echo "Test: a last line without a newline is numbered and counted"
s=$(ctx_session go go-module a.go)
printf 'one\ntwo' >"$s/tree/a.go"
add_hunk "$s" a.go 1 1
bash "$BUILD" "$s" >/dev/null
line2=$(printf '%6d\ttwo' 2)
assert_match_count "$(<"$s/prompts/batch1-context.md")" "1" "line 2 numbered" -xF "$line2"
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].outside' "true" "line 2 lies outside hunk 1..1"
rm -rf "$s"

echo "Test: an over-cap file is reported over cap even when it is binary"
s=$(ctx_session go go-module big.bin)
{
	printf 'a\0b\n'
	head -c 40000 /dev/zero | tr '\0' 'x'
} >"$s/tree/big.bin"
bash "$BUILD" "$s" >/dev/null
assert_jq "$s/prompts/context.json" '.rounds[0].files[0].reason' "over cap" "size is tested before content"
rm -rf "$s"

echo "Test: a failed rebuild leaves the previous prompts/ intact and no staging dir"
s=$(ctx_session go go-module a.go)
printf 'package a\n' >"$s/tree/a.go"
bash "$BUILD" "$s" >/dev/null
before=$(cksum <"$s/prompts/preamble.md")
fake=$(mktemp -d)
cp -R "$SCRIPT_DIR/../skills/review-council" "$fake/review-council"
sed '/^## Calibration Notes$/d' "$fake/review-council/references/lang-go.md" >"$fake/lang-go.md"
mv "$fake/lang-go.md" "$fake/review-council/references/lang-go.md"
rc=0
bash "$fake/review-council/scripts/rc-build-context.sh" "$s" >/dev/null 2>&1 || rc=$?
assert_equals "$rc" "1" "the rebuild fails"
after=$(cksum <"$s/prompts/preamble.md")
assert_equals "$after" "$before" "previous preamble kept"
assert_jq "$s/prompts/context.json" '.rounds | length' "1" "previous index kept"
leftover=$(find "$s" -maxdepth 1 -name '.prompts.*' | wc -l)
assert_equals "$((leftover))" "0" "no staging dir left behind"
rm -rf "$s" "$fake"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
