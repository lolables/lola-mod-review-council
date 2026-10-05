#!/usr/bin/env bash
# Tests for ctx-usage-sum.sh: the stream-json -> token-figures filter the
# context-mode pre-screen is built on. See ctx-usage-sum.sh for why
# prefix_tokens is the figure that matters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USAGE_SUM="$SCRIPT_DIR/ctx-usage-sum.sh"
FIXTURE="$SCRIPT_DIR/testdata/usage-basic.jsonl"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"

echo "Test 1: basic fixture reduces to the five comparison figures"
out=$(bash "$USAGE_SUM" <"$FIXTURE")
assert_jq_str "$out" '.prefix_tokens' '2010' "prefix is first assistant turn (10 + 2000 + 0)"
assert_jq_str "$out" '.total_output' '120' "total output comes from the result event"
assert_jq_str "$out" '.total_cache_read' '2000' "cache read comes from the result event"
assert_jq_str "$out" '.turns' '2' "turn count comes from the result event"
assert_jq_str "$out" '.total_cost_usd' '0.25' "cost comes from the result event"

echo "Test 2: empty stdin is refused, not silently reported as zero cost"
status=0
err=$(printf '' | bash "$USAGE_SUM" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "empty stdin exits non-zero rather than reporting a false zero"
assert_equals "$err" "ERROR: no stream-json on stdin" "empty stdin names the actual failure"

echo "Test 3: no assistant events (truncated capture) is refused, not reported as a zero prefix"
status=0
err=$(bash "$USAGE_SUM" <"$SCRIPT_DIR/testdata/usage-no-assistant.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a transcript with no assistant events exits non-zero"
assert_equals "$err" "ERROR: no assistant events found in transcript" "missing-assistant-events names the actual failure"

echo "Test 4: a first assistant event with no usage block is refused, not silently swapped for the next turn's"
status=0
err=$(bash "$USAGE_SUM" <"$SCRIPT_DIR/testdata/usage-missing-first-usage.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a first assistant event missing its usage block exits non-zero"
assert_equals "$err" "ERROR: first assistant event has no usage block — refusing to substitute a later turn" "missing-first-usage names the actual failure"

echo "Test 5: no result event (aborted run) is refused, not reported as zero output/turns/cost"
status=0
err=$(bash "$USAGE_SUM" <"$SCRIPT_DIR/testdata/usage-no-result.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a transcript with no result event exits non-zero"
assert_equals "$err" "ERROR: no result event found in transcript (run may have been aborted)" "missing-result-event names the actual failure"

VOLUME_SPLIT="$SCRIPT_DIR/ctx-volume-split.sh"
VOLUME_FIXTURE="$SCRIPT_DIR/testdata/volume-basic.jsonl"

echo "Test 6: basic fixture splits compressible from incompressible tool-result bytes"
out=$(bash "$VOLUME_SPLIT" <"$VOLUME_FIXTURE")
assert_jq_str "$out" '.compressible_bytes' '12' "compressible is Read 10 + Bash 2"
assert_jq_str "$out" '.incompressible_bytes' '5' "incompressible is Agent 5"
assert_jq_str "$out" '.agent_dispatches' '1' "one Agent tool_use counted as one dispatch"
assert_jq_str "$out" '.turns' '3' "turn count comes from the result event"

echo "Test 7: empty stdin is refused, not silently reported as zero volume"
status=0
err=$(printf '' | bash "$VOLUME_SPLIT" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "empty stdin exits non-zero rather than reporting a false zero"
assert_equals "$err" "ERROR: no stream-json on stdin" "empty stdin names the actual failure"

echo "Test 8: a transcript with zero tool results is refused, not reported as zero compressible volume"
status=0
err=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-no-tools.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a transcript with no tool_use/tool_result events exits non-zero"
assert_equals "$err" "ERROR: no tool results found in transcript" "no-tool-results names the actual failure"

echo "Test 9: no result event (aborted run) is refused, not reported as zero turns"
status=0
err=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-no-result.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a transcript with no result event exits non-zero"
assert_equals "$err" "ERROR: no result event found in transcript (run may have been aborted)" "missing-result-event names the actual failure"

echo "Test 10: a tool_result with no matching tool_use is refused, not silently miscounted"
status=0
err=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-orphan-result.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "an orphaned tool_result (unresolvable tool_use_id) exits non-zero"
assert_equals "$err" "ERROR: tool_result with unresolved tool_use_id — cannot classify its bytes as compressible or not" "orphaned tool_result names the actual failure"

echo "Test 11: a content block of an unrecognised type is refused, not silently counted as zero bytes"
status=0
err=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-mixed-content-block.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a tool_result content array with a non-text, non-tool_reference block exits non-zero"
assert_equals "$err" "ERROR: tool_result content block with unrecognised type(s) image — cannot classify its bytes as compressible or not" "unrecognised content block names the actual failure and the type"

echo "Test 12: a tool_reference content block (deferred-tool listing, not raw tool output) is recognised and contributes zero bytes"
out=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-tool-reference-block.jsonl")
assert_jq_str "$out" '.compressible_bytes' '0' "ToolSearch is not in the compressible tool list"
assert_jq_str "$out" '.incompressible_bytes' '3' "only the text block (\"abc\") counts; the tool_reference block is zero-cost metadata"
assert_jq_str "$out" '.agent_dispatches' '0' "no Agent tool_use in this fixture"

echo "Test 13: multi-byte characters are sized in bytes, not codepoints"
out=$(bash "$VOLUME_SPLIT" <"$SCRIPT_DIR/testdata/volume-multibyte.jsonl")
assert_jq_str "$out" '.compressible_bytes' '6' "héllo is 5 codepoints but 6 UTF-8 bytes"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
