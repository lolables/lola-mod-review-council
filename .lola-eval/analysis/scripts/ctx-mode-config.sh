#!/usr/bin/env bash
# Emit the two config files that enable context-mode for a single `claude`
# invocation, into the directory given as $1. Prints nothing; the caller
# passes the files via --settings and --mcp-config (and should also pass
# --strict-mcp-config — see the note above the mcp.json write below).
#
# Context-mode is not a marketplace plugin on this host: it is six
# settings.json hook entries plus an MCP server. Copying the host's live
# hook block rather than hand-writing one keeps the eval measuring the thing
# the operator actually runs, and fails loudly if that block ever moves.
#
# The host settings.json is NOT copied wholesale. Its UserPromptSubmit array
# holds two matcher blocks on this host — one for context-mode, one for
# `codegraph prompt-hook` — and PostToolUse/PreToolUse carry context-mode's
# entry alongside a broad matcher that would otherwise pull in whatever else
# shares that event. A verbatim `{hooks: .hooks}` copy would inject every
# other tool's hooks (codegraph, and anything added later) into the eval,
# which is a correctness bug for the experiment: it would measure
# context-mode-plus-whatever-else-is-installed, not context-mode alone, and
# that contamination would silently change with every unrelated plugin
# install on the eval host. So this script filters each event's hooks array
# down to entries whose command's own executable token (the first
# whitespace-delimited word, unquoted if the command opens with a quoted
# path) has the context-mode binary's basename — not merely contains it
# as a substring. An unanchored `contains`/`test($bin)` match would sweep in
# any future hook whose command happens to mention "context-mode" anywhere —
# a wrapper script, a log message, an argument — none of which are the
# context-mode hook itself.
#
# CONTROL-ARM WARNING for whoever wires the "off" side of the eval: on a
# RiotBox host with RIOTBOX_CONTEXT_MODE=1, the container entrypoint wires
# context-mode's MCP server into $CLAUDE_CONFIG_DIR/.claude.json once at
# boot, globally, outside of any --settings/--mcp-config flag. A `claude`
# invocation with neither flag still connects to it (as
# `mcp__plugin_context-mode_context-mode__ctx_*`) on this host — omitting
# the flags this script produces is NOT a clean control. Verified: with the
# default (inherited) CLAUDE_CONFIG_DIR, a flagless run's `system/init`
# event lists `plugin_context-mode_context-mode` as connected; with
# CLAUDE_CONFIG_DIR pointed at an empty scratch directory, the same flagless
# run lists no MCP servers at all. The control arm must run with an isolated
# CLAUDE_CONFIG_DIR (or the global wiring stripped) to get a real "off".
# Symmetric trap on the treatment side: on a non-isolated CLAUDE_CONFIG_DIR,
# omitting --strict-mcp-config lets the CLI merge this script's mcp.json
# with the container's own global registration — both under the same
# server name — and the session gets 22 duplicate ctx_* tools instead of
# 11. --strict-mcp-config is not optional polish; without it the treatment
# arm silently doubles up.
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "ERROR: usage: ctx-mode-config.sh <out_dir>" >&2
	exit 1
fi
out_dir="$1"
mkdir -p "$out_dir"

binary="$(command -v context-mode || true)"
if [[ -z $binary ]]; then
	echo "ERROR: context-mode not on PATH — cannot build the treatment arm" >&2
	exit 1
fi

host_settings="${CTX_HOST_SETTINGS:-$HOME/.claude/settings.json}"

# Validate .hooks is present, is an object, and every event's value is
# actually an array — not just that a key is present. `{"hooks":{"PreToolUse":null}}`
# passes a bare `has("PreToolUse")` check and then crashes the filter below
# with a raw "Cannot iterate over null (null)" and exit 5. Shape is checked
# in one pass here so a malformed host file fails loud with a clear message
# instead of a jq stack trace.
if ! hooks_shape="$(jq -r '
	if (.hooks == null) then
		"missing"
	elif (.hooks | type) != "object" then
		"not-object:\(.hooks | type)"
	else
		(.hooks | to_entries | map(select((.value | type) != "array")) | .[0]) as $bad
		| if $bad then "malformed-event:\($bad.key):\($bad.value | type)" else "ok" end
	end
' "$host_settings" 2>/dev/null)"; then
	echo "ERROR: $host_settings could not be read as JSON" >&2
	exit 1
fi

if [[ "$hooks_shape" != "ok" ]]; then
	echo "ERROR: $host_settings hooks block is malformed ($hooks_shape) — refusing to build the treatment arm" >&2
	exit 1
fi

# As with the sibling filters (ctx-usage-sum.sh, ctx-volume-split.sh), the
# "did the filter keep anything" check is folded into this one jq program
# rather than run as a second pass: it emits {error: "..."} when nothing
# survived, and bash below checks .error the same way both siblings do.
# The shape check above already guarantees $host_settings parses and every
# hook event is an array, so — unlike that first pass — this jq call has
# nothing left to fail on except the condition it reports itself.
filtered="$(jq --arg bin "$(basename "$binary")" --arg full "$binary" --arg settings "$host_settings" '
	# The executable token of a hook command: the quoted path if the command
	# opens with one (the shape this repo writes: `"\(bin)\" hook ..."`), else
	# the first whitespace-delimited word. Either way, reduced to its
	# basename so the comparison below is an exact-token match, not a
	# substring sweep.
	def cmd_basename:
		sub("^[ \t]+"; "") as $s
		| (if ($s | test("^\"")) then
				($s | capture("^\"(?<tok>[^\"]*)\"")).tok
			else
				($s | split(" ") | first)
			end)
		| split("/")
		| last;

	(.hooks
		| to_entries
		| map(.value |= (
			map(.hooks |= map(select(.command | cmd_basename == $bin)))
			| map(select((.hooks | length) > 0))
		))
		| map(select((.value | length) > 0))
		| from_entries) as $kept
	| if ($kept | length) == 0 then
			{error: "\($settings) has a hooks block but no entry invokes context-mode (\($full)) — nothing to inject"}
		else
			{hooks: $kept}
		end
' "$host_settings")"

filter_err="$(jq -r '.error // empty' <<<"$filtered")"
if [[ -n "$filter_err" ]]; then
	echo "ERROR: $filter_err" >&2
	exit 1
fi

printf '%s\n' "$filtered" >"$out_dir/settings.json"

# --strict-mcp-config is required on the `claude` invocation that consumes
# this file: without it, the CLI still merges in any MCP servers configured
# elsewhere (project .mcp.json, user-level config, or — on a RiotBox host —
# the global registration described in the CONTROL-ARM WARNING above), which
# would let a non-context-mode server leak into the treatment arm, or double
# up context-mode itself. This script cannot force that flag on the caller,
# so both consumers (the Phase 1 probe and the Phase 2 treatment arm) must
# pass it alongside --mcp-config.
#
# The server name is NOT cosmetic: context-mode's own hooks hardcode their
# redirect target as `mcp__plugin_context-mode_context-mode__<tool>` (the
# name Claude Code produces when the server arrives via context-mode's own
# marketplace plugin, which namespaces it as `plugin_<plugin>_<server>`).
# Registering it under any other name — e.g. plain "context-mode" — still
# lets the tools connect and appear in the tool list, but every redirect the
# PreToolUse hook fires points at a tool name that does not exist in the
# session: a denial with no reachable alternative, which is worse than
# leaving the feature off. Matching this exact name is what makes the
# redirect resolve.
jq -n --arg cmd "$binary" '{mcpServers: {"plugin_context-mode_context-mode": {command: $cmd}}}' \
	>"$out_dir/mcp.json"
