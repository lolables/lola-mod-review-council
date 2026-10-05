#!/usr/bin/env bash
# Tests for ctx-tax-reduce.sh: the pure filter that turns per-sample
# {off, on} arm results into the tax figure ctx-measure-tax.sh reports, and
# the self-check gate that refuses to report one when the arms did not
# actually differ the way the experiment requires. See ctx-tax-reduce.sh for
# why that gate lives here rather than in the live-run script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAX_REDUCE="$SCRIPT_DIR/ctx-tax-reduce.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"

echo "Test 1: odd sample count reduces to the middle value"
out=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-basic-odd.jsonl")
assert_jq_str "$out" '.median_fixed_tax_tokens' '300' "sorted [250,300,400], odd n picks the middle"
assert_jq_str "$out" '(.samples | length)' '3' "all three samples pass through"
assert_jq_str "$out" '.samples[0].fixed_tax_tokens' '300' "sample 0 tax is on - off (1300 - 1000)"
assert_jq_str "$out" '.samples[0].mcp_servers_off' '[]' "off arm mcp_servers carried through verbatim"
assert_jq_str "$out" '(.samples[0].mcp_servers_on | length)' '1' "on arm mcp_servers carried through verbatim"

echo "Test 2: even sample count averages the two middle values"
out=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-basic-even.jsonl")
assert_jq_str "$out" '.median_fixed_tax_tokens' '250' "sorted [100,200,300,400], even n averages 200 and 300"
assert_jq_str "$out" '(.samples | length)' '4' "all four samples pass through"

echo "Test 3: an off arm that connected an MCP server is refused, not folded into the median"
status=0
err=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-off-nonempty.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a non-empty off-arm mcp_servers exits non-zero"
assert_equals "$err" "ERROR: sample 1: off arm connected 1 MCP server(s) ([{\"name\":\"some-other-server\",\"status\":\"connected\"}]) — not a clean control" "off-arm contamination names the actual failure and the servers seen"

echo "Test 4: an on arm that never connected context-mode is refused, not folded into the median"
status=0
err=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-on-missing-context-mode.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "an on-arm missing plugin_context-mode_context-mode exits non-zero"
assert_equals "$err" "ERROR: sample 1: on arm did not connect plugin_context-mode_context-mode ([{\"name\":\"some-other-server\",\"status\":\"connected\"}]) — treatment arm did not load context-mode" "on-arm non-connection names the actual failure and the servers seen"

echo "Test 5: a null off-arm mcp_servers (missing system/init event) is refused, not treated as a clean control"
status=0
err=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-null-mcp-servers-off.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a null off-arm mcp_servers exits non-zero"
assert_equals "$err" "ERROR: sample 1: off arm has no mcp_servers recorded (missing system/init event) — cannot verify it was a clean control" "null off-arm mcp_servers names the actual failure"

echo "Test 6: a null on-arm mcp_servers (missing system/init event) is refused, not treated as context-mode connecting"
status=0
err=$(bash "$TAX_REDUCE" <"$SCRIPT_DIR/testdata/tax-null-mcp-servers-on.jsonl" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a null on-arm mcp_servers exits non-zero"
assert_equals "$err" "ERROR: sample 1: on arm has no mcp_servers recorded (missing system/init event) — cannot verify context-mode connected" "null on-arm mcp_servers names the actual failure"

echo "Test 7: empty stdin is refused, not silently reported as zero samples"
status=0
err=$(printf '' | bash "$TAX_REDUCE" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "empty stdin exits non-zero rather than reporting a false result"
assert_equals "$err" "ERROR: no sample data on stdin" "empty stdin names the actual failure"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
