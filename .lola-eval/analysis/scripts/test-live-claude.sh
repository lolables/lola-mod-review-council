#!/usr/bin/env bash
# Tests for lib/live-claude.sh's check_named_agents: the gate that stops an
# adoption probe from trusting an arm whose reviewers ran as generic agents
# because the module's agent types never registered (#109).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"
# check_named_agents exits the calling shell on failure, so each case runs it
# in a child bash, the same way it ends a probe.
LIB="$SCRIPT_DIR/lib/live-claude.sh"
# shellcheck disable=SC2016 # $1/$@ belong to the child bash, not this shell
CHECK='source "$1"; shift; check_named_agents "$@"'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

module_dir="$work/module"
mkdir -p "$module_dir/agents"
touch "$module_dir/agents/divisor-guard-code.md" "$module_dir/agents/review-council-arbiter.md"

write_transcript() { # file agents_json
	printf '%s\n' \
		"{\"type\":\"system\",\"subtype\":\"init\",\"agents\":$2}" \
		'{"type":"result","result":"done"}' >"$1"
}

echo "Test 1: every module agent registered (plus host built-ins) passes"
write_transcript "$work/named.jsonl" '["claude","divisor-guard-code","Explore","review-council-arbiter"]'
status=0
err=$(bash -c "$CHECK" _ "$LIB" "$work/named.jsonl" "$module_dir" "named arm" 2>&1) || status=$?
assert_equals "$status" "0" "all module agents present in init.agents"
assert_equals "$err" "" "a passing check prints nothing"

echo "Test 2: a module agent missing from init.agents aborts and names it"
write_transcript "$work/partial.jsonl" '["claude","divisor-guard-code","Explore"]'
status=0
err=$(bash -c "$CHECK" _ "$LIB" "$work/partial.jsonl" "$module_dir" "partial arm" 2>&1) || status=$?
assert_equals "$status" "1" "missing review-council-arbiter exits non-zero"
assert_match_count "$err" 1 "named the missing arbiter" -F "partial arm): review-council-arbiter —"

echo "Test 3: the raw-copy symptom (only host built-ins registered) aborts naming every agent"
write_transcript "$work/unnamed.jsonl" '["claude","Explore","general-purpose","Plan","statusline-setup"]'
status=0
err=$(bash -c "$CHECK" _ "$LIB" "$work/unnamed.jsonl" "$module_dir" "unnamed arm" 2>&1) || status=$?
assert_equals "$status" "1" "generic-agent fallback exits non-zero"
assert_match_count "$err" 1 "names both module agents" -F "divisor-guard-code review-council-arbiter"

echo "Test 4: a transcript with no init event aborts rather than passing vacuously"
printf '%s\n' '{"type":"result","result":"done"}' >"$work/no-init.jsonl"
status=0
err=$(bash -c "$CHECK" _ "$LIB" "$work/no-init.jsonl" "$module_dir" "no-init arm" 2>&1) || status=$?
assert_equals "$status" "1" "missing init event exits non-zero"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
