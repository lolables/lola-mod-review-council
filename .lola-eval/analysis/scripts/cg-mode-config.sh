#!/usr/bin/env bash
# Emit the two config files that enable CodeGraph for a single `claude`
# invocation, into the directory given as $1. Prints nothing; the caller
# passes the files via --settings and --mcp-config (and should also pass
# --strict-mcp-config — see the note above the mcp.json write below).
#
# Sibling of ctx-mode-config.sh, built for the codegraph/context-mode
# substitution probe (cg-adoption-probe.sh): same shape, same guard
# discipline, but CodeGraph's two live wiring sources are split across two
# host files instead of one. Its UserPromptSubmit hook lives in
# ~/.claude/settings.json alongside context-mode's (see
# ctx-mode-config.sh's header for why the host file isn't copied wholesale);
# its MCP server is registered globally in ~/.claude.json, not settings.json
# — `jq '.mcpServers' ~/.claude.json` on this host returns
# `{"codegraph": {"type": "stdio", "command": "codegraph", "args": ["serve",
# "--mcp"]}}`, confirmed before writing this script rather than assumed.
#
# CONTROL-ARM WARNING mirrors ctx-mode-config.sh's: on a RiotBox host with
# RIOTBOX_CONTEXT_MODE=1, the container wires context-mode into
# $CLAUDE_CONFIG_DIR/.claude.json at boot; codegraph's own registration is
# also host-global (~/.claude.json), so the same isolated-CLAUDE_CONFIG_DIR
# discipline applies here — a flagless run under an isolated config dir
# connects neither MCP server. --strict-mcp-config is required on the
# consuming `claude` invocation for the same reason as ctx-mode-config.sh's:
# without it, the CLI merges this script's mcp.json with whatever is
# registered elsewhere, silently doubling up the codegraph server.
#
# The server name is NOT cosmetic. Codegraph's MCP tool surfaces as
# `mcp__codegraph__codegraph_explore` — the name is exactly the top-level key
# under `.mcpServers` in ~/.claude.json, not a plugin-namespaced form like
# context-mode's `plugin_<plugin>_<server>`. Registering it under any other
# name changes the tool's visible name and breaks the standing CLAUDE.md
# instruction, which names it as `codegraph_explore`.
set -euo pipefail

if [[ $# -lt 1 ]]; then
	echo "ERROR: usage: cg-mode-config.sh <out_dir>" >&2
	exit 1
fi
out_dir="$1"
mkdir -p "$out_dir"

binary="$(command -v codegraph || true)"
if [[ -z $binary ]]; then
	echo "ERROR: codegraph not on PATH — cannot build the codegraph arm" >&2
	exit 1
fi

host_settings="${CG_HOST_SETTINGS:-$HOME/.claude/settings.json}"
host_claude_json="${CG_HOST_CLAUDE_JSON:-$HOME/.claude.json}"

# Validate .hooks is present, is an object, and every event's value is
# actually an array — same shape check as ctx-mode-config.sh, for the same
# reason: a malformed host file must fail loud with a clear message instead
# of a jq stack trace three lines later.
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
	echo "ERROR: $host_settings hooks block is malformed ($hooks_shape) — refusing to build the codegraph arm" >&2
	exit 1
fi

# Same anchored-basename filter as ctx-mode-config.sh's cmd_basename: the
# executable token of a hook command, reduced to its basename, so the
# comparison is an exact-token match, not a substring sweep. codegraph's own
# hook entry is a bare word ("codegraph prompt-hook", no quoted path), which
# this handles via the unquoted branch — verified against the live host
# settings.json before writing this script.
filtered="$(jq --arg bin "$(basename "$binary")" --arg full "$binary" --arg settings "$host_settings" '
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
			{error: "\($settings) has a hooks block but no entry invokes codegraph (\($full)) — nothing to inject"}
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

# The MCP server entry is read from the host's ~/.claude.json rather than
# hand-written, for the same discovery-over-hard-coding reason
# ctx-mode-config.sh derives its hooks from the live settings.json instead of
# a checked-in copy: the args codegraph's server needs (`serve --mcp`) are
# CodeGraph's own implementation detail, and hard-coding them here would
# silently drift the day that command line changes upstream. Only the
# resolved binary path is substituted in for `.command` (matching
# ctx-mode-config.sh's convention of registering the resolved binary, not a
# bare PATH-relative name that may not resolve inside the isolated
# CLAUDE_CONFIG_DIR this file gets consumed under); `.args` is carried
# through verbatim.
if ! claude_json_shape="$(jq -r '
	if (.mcpServers == null) then "missing-mcpServers"
	elif (.mcpServers.codegraph == null) then "missing-codegraph-entry"
	elif (.mcpServers.codegraph.command == null) then "missing-command"
	else "ok" end
' "$host_claude_json" 2>/dev/null)"; then
	echo "ERROR: $host_claude_json could not be read as JSON" >&2
	exit 1
fi

if [[ "$claude_json_shape" != "ok" ]]; then
	echo "ERROR: $host_claude_json has no usable mcpServers.codegraph entry ($claude_json_shape) — cannot build the codegraph arm" >&2
	exit 1
fi

codegraph_args="$(jq -c '.mcpServers.codegraph.args // []' "$host_claude_json")"
jq -n --arg cmd "$binary" --argjson args "$codegraph_args" \
	'{mcpServers: {codegraph: {command: $cmd, args: $args}}}' \
	>"$out_dir/mcp.json"
