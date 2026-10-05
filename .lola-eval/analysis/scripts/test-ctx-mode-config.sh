#!/usr/bin/env bash
# Tests for ctx-mode-config.sh: the generator that turns the host's live
# context-mode wiring into the --settings/--mcp-config pair a single `claude`
# invocation uses to switch context-mode on. Both the Phase 1 probe and the
# Phase 2 treatment arm consume this script's output, so a bug here silently
# breaks every downstream measurement.
#
# Hermetic by construction: every fixture uses a stub `context-mode` binary
# built in a scratch bin dir and prepended to PATH, never the real host
# binary or the real ~/.claude/settings.json. A CI runner with no
# context-mode installed, or a settings.json that looks nothing like this
# container's, must see the same results this suite asserts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_GEN="$SCRIPT_DIR/ctx-mode-config.sh"
# shellcheck source=module/tests/helpers.sh
source "$SCRIPT_DIR/../../../module/tests/helpers.sh"

# Stub context-mode binary. Its own behaviour is never exercised by this
# suite (the generator only ever calls `command -v` on it) — its only job is
# to exist, be executable, and resolve to a known path the fixtures can
# reference.
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_BIN="$FAKE_BIN_DIR/context-mode"
cat >"$FAKE_BIN" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$FAKE_BIN"
export PATH="$FAKE_BIN_DIR:$PATH"

# Materialise a testdata fixture with __BIN__/__BASENAME__ substituted for
# the real (per-run, mktemp-derived) stub path, into a fresh temp file.
# Fixtures are static on disk so they read cleanly in a diff; the path they
# reference can't be, since it is chosen at test run time.
render_fixture() {
	local name="$1" out
	out="$(mktemp)"
	sed -e "s#__BIN__#$FAKE_BIN#g" -e "s#__BASENAME__#context-mode#g" \
		"$SCRIPT_DIR/testdata/$name" >"$out"
	printf '%s' "$out"
}

echo "Test 1: the codegraph UserPromptSubmit entry is filtered out, context-mode's own entry survives"
settings="$(render_fixture ctxmode-settings-basic.json)"
out_dir="$(mktemp -d)"
CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit | length' '1' \
	"codegraph's matcher block is dropped, leaving one UserPromptSubmit entry"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | contains("codegraph")' 'false' \
	"the surviving UserPromptSubmit entry does not name codegraph"
assert_jq "$out_dir/settings.json" '.hooks.UserPromptSubmit[0].hooks[0].command | contains("context-mode")' 'true' \
	"the surviving UserPromptSubmit entry names context-mode"

echo "Test 2: all six context-mode hook events survive filtering"
assert_jq "$out_dir/settings.json" '.hooks | keys | sort | join(",")' \
	'PostToolUse,PreCompact,PreToolUse,SessionStart,Stop,UserPromptSubmit' \
	"every context-mode event key is present, nothing extra"

echo "Test 3: the MCP server is registered under context-mode's own redirect-target name"
assert_jq "$out_dir/mcp.json" '.mcpServers | keys | join(",")' 'plugin_context-mode_context-mode' \
	"server name matches CONTEXT_MODE_MCP_NAME — the name context-mode's own hooks hardcode as their redirect target"
assert_jq "$out_dir/mcp.json" '.mcpServers["plugin_context-mode_context-mode"].command' "$FAKE_BIN" \
	"the registered command is the resolved context-mode binary"

echo "Test 4: a hooks block that is entirely absent is refused, not silently treated as empty"
settings="$(render_fixture ctxmode-settings-hooks-missing.json)"
out_dir2="$(mktemp -d)"
status=0
err=$(CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a settings file with no .hooks key exits non-zero"
assert_equals "$err" "ERROR: $settings hooks block is malformed (missing) — refusing to build the treatment arm" \
	"missing .hooks names the actual failure"

echo "Test 5: a .hooks that is not an object is refused with a clear message, not a jq crash"
settings="$(render_fixture ctxmode-settings-hooks-not-object.json)"
status=0
err=$(CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a .hooks that is a string exits non-zero"
assert_equals "$err" "ERROR: $settings hooks block is malformed (not-object:string) — refusing to build the treatment arm" \
	"non-object .hooks names the actual failure and its type"

echo "Test 6: a hook event present but null ({\"hooks\":{\"PreToolUse\":null}}) is refused, not a raw jq crash"
settings="$(render_fixture ctxmode-settings-event-null.json)"
status=0
err=$(CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a null PreToolUse event exits non-zero, not the jq default exit 5"
assert_equals "$err" "ERROR: $settings hooks block is malformed (malformed-event:PreToolUse:null) — refusing to build the treatment arm" \
	"the malformed event names the offending key and its actual type"

echo "Test 7: a well-shaped hooks block with no context-mode entry anywhere is refused, not emitted empty"
settings="$(render_fixture ctxmode-settings-no-context-mode.json)"
status=0
err=$(CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir2" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "a hooks block naming only other tools exits non-zero"
assert_equals "$err" "ERROR: $settings has a hooks block but no entry invokes context-mode ($FAKE_BIN) — nothing to inject" \
	"the no-context-mode case names the binary it looked for"

echo "Test 8: the basename match is anchored to the command's executable token, not a substring sweep"
settings="$(render_fixture ctxmode-settings-anchor-trap.json)"
out_dir3="$(mktemp -d)"
CTX_HOST_SETTINGS="$settings" bash "$CONFIG_GEN" "$out_dir3"
assert_jq "$out_dir3/settings.json" '.hooks.PreToolUse[0].hooks | length' '1' \
	"only the real context-mode entry survives — the not-context-mode-wrapper entry is excluded"
assert_jq "$out_dir3/settings.json" '.hooks.PreToolUse[0].hooks[0].command | contains("not-")' 'false' \
	"the surviving entry is not the trap command"

echo "Test 9: context-mode absent from PATH is refused before touching any settings file"
out_dir4="$(mktemp -d)"
status=0
err=$(env PATH="/usr/bin:/bin" bash "$CONFIG_GEN" "$out_dir4" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "no context-mode binary on PATH exits non-zero"
assert_equals "$err" "ERROR: context-mode not on PATH — cannot build the treatment arm" \
	"missing-binary names the actual failure"

echo "Test 10: an unreadable/empty host settings file is refused, not treated as a valid empty hooks block"
out_dir5="$(mktemp -d)"
status=0
err=$(CTX_HOST_SETTINGS=/dev/null bash "$CONFIG_GEN" "$out_dir5" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "/dev/null as the host settings file exits non-zero"

echo "Test 11: a missing \$1 is refused with the file's own ERROR-prefixed, exit-1 contract, not bash's own diagnostic"
status=0
err=$(bash "$CONFIG_GEN" 2>&1 1>/dev/null) || status=$?
assert_equals "$status" "1" "no out_dir argument exits 1, not bash's own exit 127"
assert_equals "$err" "ERROR: usage: ctx-mode-config.sh <out_dir>" \
	"missing-argument uses the same ERROR:-prefixed contract as every other guard in this file"

rm -rf "$FAKE_BIN_DIR" "$out_dir" "$out_dir2" "$out_dir3" "$out_dir4" "$out_dir5"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
