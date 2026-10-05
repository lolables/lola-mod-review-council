#!/usr/bin/env bash
# Tests for ctx-routing-rate.sh: the filter that reduces a stream-json
# transcript to the context-mode adoption rate — the headline figure the
# live adoption probe (ctx-adoption-probe.sh) reports per arm.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUTING_RATE="$SCRIPT_DIR/ctx-routing-rate.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"

echo "Test 1: mixed transcript computes the ratio of context-mode calls to all tool calls"
out=$(bash "$ROUTING_RATE" <"$SCRIPT_DIR/testdata/routing-basic.jsonl")
assert_jq_str "$out" '.total_tool_calls' '4' "four tool_use events total"
assert_jq_str "$out" '.context_mode_tool_calls' '1' "one of the four is a context-mode tool"
assert_jq_str "$out" '.routing_rate' '0.25' "1/4 routed through context-mode"
assert_jq_str "$out" '.tool_histogram.Read' '1' "histogram counts Read"
assert_jq_str "$out" '.tool_histogram["mcp__plugin_context-mode_context-mode__ctx_batch_execute"]' '1' \
	"histogram counts the context-mode tool under its full name"

echo "Test 2: every call routed through context-mode gives a rate of 1"
out=$(bash "$ROUTING_RATE" <"$SCRIPT_DIR/testdata/routing-all-context-mode.jsonl")
assert_jq_str "$out" '.routing_rate' '1' "all calls are context-mode tools"
assert_jq_str "$out" '.context_mode_tool_calls' '2' "both calls counted"

echo "Test 3: no context-mode calls gives a rate of 0, not an error"
out=$(bash "$ROUTING_RATE" <"$SCRIPT_DIR/testdata/routing-no-context-mode.jsonl")
assert_jq_str "$out" '.routing_rate' '0' "a genuine zero is a valid, reportable rate"
assert_jq_str "$out" '.context_mode_tool_calls' '0' "no context-mode tool names present"
assert_jq_str "$out" '.total_tool_calls' '2' "denominator still reflects the real call count"

echo "Test 4: empty stdin is refused, not silently reported as a zero rate"
status=0
err=$(printf '' | bash "$ROUTING_RATE" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "empty stdin exits non-zero rather than reporting a false rate"
assert_equals "$err" "ERROR: no stream-json on stdin" "empty stdin names the actual failure"

echo "Test 5: a transcript with no tool calls at all is refused, not divided by zero"
status=0
err=$(bash "$ROUTING_RATE" <"$SCRIPT_DIR/testdata/routing-no-tools.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "zero tool calls exits non-zero rather than a NaN/divide-by-zero rate"
assert_equals "$err" "ERROR: no tool calls found in transcript" "missing-tool-calls names the actual failure"

echo "Test 6: no result event (aborted run) is refused, not reported as a genuine rate"
status=0
err=$(bash "$ROUTING_RATE" <"$SCRIPT_DIR/testdata/routing-no-result.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a transcript with no result event exits non-zero"
assert_equals "$err" "ERROR: no result event found in transcript (run may have been aborted)" \
	"missing-result-event names the actual failure — a truncated run must not masquerade as a measurement"
