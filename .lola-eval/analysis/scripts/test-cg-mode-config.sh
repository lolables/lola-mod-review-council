#!/usr/bin/env bash
# Tests for cg-mode-config.sh: the generator that turns the host's live
# CodeGraph wiring into the --settings/--mcp-config pair a single `claude`
# invocation uses to switch CodeGraph on. cg-adoption-probe.sh's codegraph
# and both arms consume this script's output, so a bug here silently breaks
# every downstream measurement — same stakes as test-ctx-mode-config.sh for
# its sibling.
#
# Hermetic by construction: every fixture uses a stub `codegraph` binary
# built in a scratch bin dir and prepended to PATH, and both host files
# (settings.json's hooks, .claude.json's mcpServers) are injected via
# CG_HOST_SETTINGS/CG_HOST_CLAUDE_JSON — never the real host files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_GEN="$SCRIPT_DIR/cg-mode-config.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"

# Stub codegraph binary. Its own behaviour is never exercised by this suite
# (the generator only ever calls `command -v` on it) — its only job is to
# exist, be executable, and resolve to a known path the fixtures can
# reference.
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_BIN="$FAKE_BIN_DIR/codegraph"
cat >"$FAKE_BIN" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN"
export PATH="$FAKE_BIN_DIR:$PATH"

# A default, valid .claude.json fixture most tests reuse unchanged — only
# the tests exercising its own guards render a different one.
default_claude_json="$SCRIPT_DIR/testdata/cgmode-claude-json-basic.json"

# Materialise a testdata fixture with __BIN__/__BASENAME__ substituted for
# the real (per-run, mktemp-derived) stub path, into a fresh temp file.
# Fixtures are static on disk so they read cleanly in a diff; the path they
# reference can't be, since it is chosen at test run time.
render_fixture() {
	local name="$1" out
	out="$(mktemp)"
	sed -e "s#__BIN__#$FAKE_BIN#g" -e "s#__BASENAME__#codegraph#g" \
		"$SCRIPT_DIR/testdata/$name" >"$out"
	printf '%s' "$out"
}

echo "Test 1: context-mode's UserPromptSubmit entry is filtered out, codegraph's own entry survives"
settings="$(render_fixture cgmode-settings-basic.json)"
out_dir="$(mktemp -d)"
CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit | length' '1' \
	"context-mode's matcher block is dropped, leaving one UserPromptSubmit entry"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | contains("context-mode")' 'false' \
	"the surviving UserPromptSubmit entry does not name context-mode"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | contains("codegraph")' 'true' \
	"the surviving UserPromptSubmit entry names codegraph"

echo "Test 2: only the codegraph-bearing event key survives — PreToolUse has no codegraph entry on this host"
assert_jq "$out_dir/settings.json" '.hooks | keys | join(",")' 'UserPromptSubmit' \
	"PreToolUse (context-mode-only) is dropped entirely, not kept empty"

echo "Test 3: the MCP server is registered under codegraph's own tool-namespace name, with args carried through"
assert_jq "$out_dir/mcp.json" '.mcpServers | keys | join(",")' 'codegraph' \
	"server name matches the top-level mcpServers key — the name codegraph's tools surface under (mcp__codegraph__codegraph_explore)"
assert_jq "$out_dir/mcp.json" '.mcpServers.codegraph.command' "$FAKE_BIN" \
	"the registered command is the resolved codegraph binary"
assert_jq "$out_dir/mcp.json" '.mcpServers.codegraph.args | join(",")' 'serve,--mcp' \
	"args are carried through from the host's .claude.json verbatim, not hard-coded"

echo "Test 4: a hooks block that is entirely absent is refused, not silently treated as empty"
settings="$(render_fixture cgmode-settings-hooks-missing.json)"
out_dir2="$(mktemp -d)"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a settings file with no .hooks key exits non-zero"
assert_equals "$err" "ERROR: $settings hooks block is malformed (missing) — refusing to build the codegraph arm" \
	"missing .hooks names the actual failure"

echo "Test 5: a .hooks that is not an object is refused with a clear message, not a jq crash"
settings="$(render_fixture cgmode-settings-hooks-not-object.json)"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a .hooks that is a string exits non-zero"
assert_equals "$err" "ERROR: $settings hooks block is malformed (not-object:string) — refusing to build the codegraph arm" \
	"non-object .hooks names the actual failure and its type"

echo "Test 6: a hook event present but null is refused, not a raw jq crash"
settings="$(render_fixture cgmode-settings-event-null.json)"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a null PreToolUse event exits non-zero, not the jq default exit 5"
assert_equals "$err" "ERROR: $settings hooks block is malformed (malformed-event:PreToolUse:null) — refusing to build the codegraph arm" \
	"the malformed event names the offending key and its actual type"

echo "Test 7: a well-shaped hooks block with no codegraph entry anywhere is refused, not emitted empty"
settings="$(render_fixture cgmode-settings-no-codegraph.json)"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a hooks block naming only other tools exits non-zero"
assert_equals "$err" "ERROR: $settings has a hooks block but no entry invokes codegraph ($FAKE_BIN) — nothing to inject" \
	"the no-codegraph case names the binary it looked for"

echo "Test 8: the basename match is anchored to the command's executable token, not a substring sweep"
settings="$(render_fixture cgmode-settings-anchor-trap.json)"
out_dir3="$(mktemp -d)"
CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir3"
assert_jq "$out_dir3/settings.json" '.hooks.UserPromptSubmit[0].hooks | length' '1' \
	"only the real codegraph entry survives — the not-codegraph-wrapper entry is excluded"
assert_jq "$out_dir3/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | contains("not-")' 'false' \
	"the surviving entry is not the trap command"

echo "Test 9: codegraph absent from PATH is refused before touching any settings file"
out_dir4="$(mktemp -d)"
status=0
err=$(env PATH="/usr/bin:/bin" bash "$CONFIG_GEN" "$out_dir4" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "no codegraph binary on PATH exits non-zero"
assert_equals "$err" "ERROR: codegraph not on PATH — cannot build the codegraph arm" \
	"missing-binary names the actual failure"

echo "Test 10: an unreadable/empty host settings file is refused, not treated as a valid empty hooks block"
out_dir5="$(mktemp -d)"
status=0
err=$(CG_HOST_SETTINGS=/dev/null CG_HOST_CLAUDE_JSON="$default_claude_json" bash "$CONFIG_GEN" "$out_dir5" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "/dev/null as the host settings file exits non-zero"

echo "Test 11: a missing \$1 is refused with the file's own ERROR-prefixed, exit-1 contract, not bash's own diagnostic"
status=0
err=$(bash "$CONFIG_GEN" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "no out_dir argument exits 1, not bash's own exit 127"
assert_equals "$err" "ERROR: usage: cg-mode-config.sh <out_dir>" \
	"missing-argument uses the same ERROR:-prefixed contract as every other guard in this file"

echo "Test 12: a host .claude.json with no mcpServers block at all is refused"
settings="$(render_fixture cgmode-settings-basic.json)"
claude_json="$SCRIPT_DIR/testdata/cgmode-claude-json-no-mcp-servers.json"
out_dir6="$(mktemp -d)"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$claude_json" bash "$CONFIG_GEN" "$out_dir6" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a .claude.json with no mcpServers key exits non-zero"
assert_equals "$err" "ERROR: $claude_json has no usable mcpServers.codegraph entry (missing-mcpServers) — cannot build the codegraph arm" \
	"missing mcpServers names the actual failure"

echo "Test 13: a host .claude.json with mcpServers but no codegraph entry is refused"
claude_json="$SCRIPT_DIR/testdata/cgmode-claude-json-no-codegraph-entry.json"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON="$claude_json" bash "$CONFIG_GEN" "$out_dir6" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "mcpServers without a codegraph key exits non-zero"
assert_equals "$err" "ERROR: $claude_json has no usable mcpServers.codegraph entry (missing-codegraph-entry) — cannot build the codegraph arm" \
	"missing codegraph entry names the actual failure"

echo "Test 14: an unreadable host .claude.json is refused, not treated as a valid empty document"
status=0
err=$(CG_HOST_SETTINGS="$settings" CG_HOST_CLAUDE_JSON=/dev/null bash "$CONFIG_GEN" "$out_dir6" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "/dev/null as the host .claude.json exits non-zero"

rm -rf "$FAKE_BIN_DIR" "$out_dir" "$out_dir2" "$out_dir3" "$out_dir4" "$out_dir5" "$out_dir6"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
