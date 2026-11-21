#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/helpers.sh"
SCRIPTS="$SCRIPT_DIR/../skills/review-council/scripts"
PREPARE_DISPATCH="$SCRIPTS/rc-prepare-dispatch.sh"
SEVERITY="$SCRIPT_DIR/../skills/review-council/references/severity.md"
REFS="$SCRIPT_DIR/../skills/review-council/references"

# Issue #107: the orchestrator re-reads the skill docs on every turn, so the
# three scripts it ran back to back (batch plan, reviewer context, dispatch
# prompts) cost three turns. rc-prepare-dispatch.sh runs them in order. The
# contract under test: the chain stops at the first status that is not `ok` and
# that script's JSON and exit code come through UNCHANGED; on success one
# combined result carries what the orchestrator acts on.
#
# Sessions are built by hand, as in test-rc-assemble-prompts.sh, except that no
# batch-plan.json is written: producing it is the wrapper's first step.

# A code-mode session over the given files, reviewed by guard and curator.
# Prints the session dir; the review root is <session>/tree.
pd_session() { # file...
	local s root f
	s=$(mktemp -d)
	root="$s/tree"
	mkdir -p "$root" "$s/review-config"
	cp "$SEVERITY" "$s/review-config/severity.md"
	printf -- '- Review root: %s\n' "$root" >"$s/session.txt"
	cat >"$s/tracking.md" <<EOF
# Review Council Session Tracking

## Phase: Preparation

- Scope: changed
- Scope value: main...HEAD
- Scope dir: none
- Tooling: gh
- PR: none
- Constitution: none
- Project packs: none
- Docs repo: acme/docs
- Mode: code (code files changed)
- Effort: standard
- Branch: feat
- Base: main
- Language: go
- Framework: go-module
- Context check lines: 6
- Review root: ${root}

EOF
	write_packs_tsv "$s" "$REFS" go go-module
	: >"$s/diff.patch"
	printf '%s\n' "$@" >"$s/changeset.txt"
	for f in "$@"; do
		seq 1 20 | sed 's/^/line /' >"$root/$f"
		{
			printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -5,4 +5,4 @@\n' "$f" "$f" "$f" "$f"
			printf '+line %d\n' 5 6 7 8
		} >>"$s/diff.patch"
	done
	printf '%s\n' divisor-guard-code divisor-curator-code |
		jq -Rn '[inputs] as $c | {mode: "code", suffix: "code", agents: $c, council: $c, subsystems: []}' >"$s/session-manifest.json"
	printf '%s' "$s"
}

# Runs the wrapper, setting out (stdout) and rc (exit code) without letting a
# non-zero exit end the test run.
pd_run() { # args...
	rc=0
	out=$(bash "$PREPARE_DISPATCH" "$@" 2>/dev/null) || rc=$?
}

echo "Test: all three steps run and one combined result comes back"
s=$(pd_session a.go)
pd_run "$s"
assert_equals "$rc" "0" "exit 0"
assert_jq_str "$out" '.status' "ok" "status ok"
assert_jq_str "$out" '.batching.applied' "false" "single batch: batching not applied"
assert_jq_str "$out" '.batching.batch_count' "1" "one batch"
diff_bytes=$(wc -c <"$s/diff.patch")
assert_jq_str "$out" '.batching.context_bytes' "${diff_bytes//[[:space:]]/}" "context bytes from the plan"
assert_jq_str "$out" '.context.rounds | length' "1" "context summary carries the round"
assert_jq_str "$out" '.prompts.prompts' "2" "two prompts assembled"
assert_jq_str "$out" '.prompts.index' "dispatch.json" "index named"
for f in batch-plan.json batches.txt prompts/context.json prompts/preamble.md dispatch.json; do
	[[ -s "$s/$f" ]] && got=yes || got=no
	assert_equals "$got" "yes" "$f written"
done
for phase in "Batch Plan" "Context" "Prompts"; do
	assert_match_count "$(<"$s/tracking.md")" "1" "tracking.md has one Phase: $phase block" -xF "## Phase: $phase"
done
rm -rf "$s"

echo "Test: a split changeset is reported in the combined result"
s=$(pd_session a.go b.go)
{
	grep -v -E '^- Batch size:' "$s/tracking.md"
	echo '- Batch size: 1'
} >"$s/tracking.md.new"
mv "$s/tracking.md.new" "$s/tracking.md"
pd_run "$s"
assert_jq_str "$out" '.status' "ok" "status ok"
assert_jq_str "$out" '.batching.applied' "true" "batching applied"
assert_jq_str "$out" '.batching.batch_count' "2" "two batches"
assert_jq_str "$out" '.prompts.prompts' "4" "two reviewers over two rounds"
message=$(jq -r '.message' <<<"$out")
assert_match_count "$message" "1" "message names the split" -F "split into 2 batches"
rm -rf "$s"

echo "Test: no session directory is nothing_to_do, exit 0, and nothing is written"
missing=$(mktemp -d)/absent
pd_run "$missing"
assert_equals "$rc" "0" "exit 0"
assert_jq_str "$out" '.status' "nothing_to_do" "status passed through"
pd_run
assert_equals "$rc" "0" "exit 0 with no argument"
assert_jq_str "$out" '.status' "nothing_to_do" "no argument is nothing_to_do"

echo "Test: step 1 non-ok stops the chain and its JSON comes through unchanged"
s=$(pd_session a.go)
rm "$s/changeset.txt"
direct=$(bash "$SCRIPTS/rc-plan-batches.sh" "$s")
pd_run "$s"
assert_equals "$rc" "0" "nothing_to_do exits 0, as the planner does"
assert_equals "$out" "$direct" "stdout is the planner's, byte for byte"
assert_jq_str "$out" '.status' "nothing_to_do" "status nothing_to_do"
[[ -e "$s/prompts" || -e "$s/dispatch.json" ]] && got=ran || got=stopped
assert_equals "$got" "stopped" "later steps did not run"
rm -rf "$s"

echo "Test: step 2 error stops the chain with its own message and exit code"
s=$(pd_session a.go)
rm "$s/review-config/severity.md"
bash "$SCRIPTS/rc-plan-batches.sh" "$s" >/dev/null
direct=$(bash "$SCRIPTS/rc-build-context.sh" "$s" 2>/dev/null) || true
pd_run "$s"
assert_equals "$rc" "1" "exit 1, as rc-build-context.sh exits"
assert_equals "$out" "$direct" "stdout is rc-build-context.sh's, byte for byte"
assert_match_count "$out" "1" "the message names the missing file" -F "review-config/severity.md is missing"
[[ -s "$s/batch-plan.json" ]] && got=yes || got=no
assert_equals "$got" "yes" "step 1 had run"
[[ -e "$s/dispatch.json" ]] && got=ran || got=stopped
assert_equals "$got" "stopped" "step 3 did not run"
rm -rf "$s"

echo "Test: step 3 error stops the chain with its own message and exit code"
s=$(pd_session a.go)
rm "$s/session-manifest.json"
pd_run "$s"
assert_equals "$rc" "1" "exit 1, as rc-assemble-prompts.sh exits"
assert_jq_str "$out" '.status' "error" "status error"
assert_match_count "$out" "1" "the message names the missing manifest" -F "session-manifest.json is missing"
[[ -s "$s/prompts/context.json" ]] && got=yes || got=no
assert_equals "$got" "yes" "step 2 had run"
[[ -e "$s/dispatch.json" ]] && got=written || got=absent
assert_equals "$got" "absent" "no index was written"
rm -rf "$s"

echo "Test: --inline-persona without AGENTS_DIR surfaces the assembler's error"
s=$(pd_session a.go)
rc=0
out=$(env -u AGENTS_DIR bash "$PREPARE_DISPATCH" "$s" --inline-persona 2>/dev/null) || rc=$?
assert_equals "$rc" "1" "exit 1"
assert_match_count "$out" "1" "the message names AGENTS_DIR" -F -- "--inline-persona needs AGENTS_DIR"
rm -rf "$s"

echo "Test: --inline-persona reaches the assembler"
s=$(pd_session a.go)
agents=$(mktemp -d)
for a in divisor-guard-code divisor-curator-code; do
	printf -- '---\ndescription: persona\n---\n\nPERSONA-%s\n' "$a" >"$agents/$a.md"
done
rc=0
out=$(AGENTS_DIR="$agents" bash "$PREPARE_DISPATCH" "$s" --inline-persona 2>/dev/null) || rc=$?
assert_equals "$rc" "0" "exit 0"
assert_match_count "$(<"$s/prompts/dispatch/divisor-guard-code.md")" "1" "the persona text is inlined" -F "PERSONA-divisor-guard-code"
assert_match_count "$(<"$s/tracking.md")" "1" "tracking records it" -xF -- "- Persona inlined: yes"
rm -rf "$s" "$agents"

echo "Test: --keep-receipts keeps the collected receipts; a plain re-run mints new ones"
s=$(pd_session a.go)
pd_run "$s"
before=$(jq -c '[.dispatches[] | {agent, raw, receipt}]' "$s/dispatch.json")
bundle_before=$(jq -c '[.rounds[].bundle_receipt]' "$s/prompts/context.json")
pd_run "$s" --keep-receipts
assert_equals "$rc" "0" "exit 0"
after=$(jq -c '[.dispatches[] | {agent, raw, receipt}]' "$s/dispatch.json")
assert_equals "$after" "$before" "dispatch receipts unchanged"
bundle_after=$(jq -c '[.rounds[].bundle_receipt]' "$s/prompts/context.json")
assert_equals "$bundle_after" "$bundle_before" "bundle receipts unchanged (same content)"
pd_run "$s"
after=$(jq -c '[.dispatches[] | {agent, raw, receipt}]' "$s/dispatch.json")
[[ "$after" != "$before" ]] && got=new || got=same
assert_equals "$got" "new" "without the flag every receipt is fresh"
rm -rf "$s"

echo "Test: --keep-receipts over a malformed index is the assembler's error"
s=$(pd_session a.go)
pd_run "$s"
printf 'not json\n' >"$s/dispatch.json"
pd_run "$s" --keep-receipts
assert_equals "$rc" "1" "exit 1"
assert_jq_str "$out" '.status' "error" "status error"
assert_match_count "$out" "1" "the message says the index is malformed" -F "malformed"
rm -rf "$s"

echo "Test: bad arguments are refused before any step runs"
s=$(pd_session a.go)
pd_run "$s" --bogus
assert_equals "$rc" "1" "unknown option: exit 1"
assert_jq_str "$out" '.status' "error" "unknown option: status error"
assert_match_count "$out" "1" "the message names the option" -F "Unknown option: --bogus"
pd_run "$s" "$s"
assert_equals "$rc" "1" "second positional: exit 1"
assert_match_count "$out" "1" "the message names the extra argument" -F "Unexpected argument"
[[ -e "$s/batch-plan.json" ]] && got=ran || got=none
assert_equals "$got" "none" "no step ran on bad arguments"
rm -rf "$s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
