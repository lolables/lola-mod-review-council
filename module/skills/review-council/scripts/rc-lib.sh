#!/usr/bin/env bash
# Shared library for review-council scripts.
# Source this file; do not execute it directly.
#
# Provides:
#   - Bash 4+, jq, and GNU timeout prerequisite checks (exits gracefully if missing)
#   - _RC_HAVE_FILE — "yes"/"no": whether file(1) is available to classify content
#   - json_output()  — structured JSON output helper
#   - build_repo_flag() — constructs --repo flag for gh/glab CLI
#   - parse_remote() — splits a git remote into host / owner / repo
#   - rc_timeout() — runs a command under the resolved GNU timeout binary

# Guard: skip if already loaded
[[ -n "${_RC_LIB_LOADED:-}" ]] && return 0
_RC_LIB_LOADED=1

if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo '{"status":"skip","message":"Bash 4+ is required. macOS ships Bash 3 — install a modern version: brew install bash"}'
	exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
	echo '{"status":"skip","message":"jq is required but not installed. Install it: apt-get install jq | brew install jq | dnf install jq"}'
	exit 0
fi

# `file(1)` classifies candidates for the binary filter, but it is a capability,
# not a prerequisite: a host without it is not a host that should be refused a
# review. Probe once here so callers can degrade to admitting the candidate
# rather than silently rejecting every one of them.
if command -v file >/dev/null 2>&1; then
	_RC_HAVE_FILE="yes"
else
	_RC_HAVE_FILE="no"
fi

# JSON output helper.
# Optional 3rd arg is a JSON object merged into the result; defaults to {}.
# NOTE: assign via a local first — the inline form ${3:-{}} is a brace-parsing
# trap (the expansion closes at the first '}', leaving a stray literal '}').
json_output() {
	local extra="${3:-}"
	[[ -z "$extra" ]] && extra="{}"
	jq -n \
		--arg status "$1" \
		--arg message "$2" \
		--argjson extra "$extra" \
		'$extra + {status: $status, message: $message}'
}

# Build --repo flag for gh/glab CLI from forge owner and repo variables.
# Usage: repo_flag=$(build_repo_flag "$forge_owner" "$forge_repo")
build_repo_flag() {
	local owner="$1" repo="$2"
	if [[ -n "$owner" ]] && [[ -n "$repo" ]]; then
		echo "--repo ${owner}/${repo}"
	fi
}

# Split a git remote into rc_remote_{host,owner,repo}. Three return values is
# why these are set rather than printed: reading them back from a command
# substitution would put the parse in a subshell for no gain. Every call site —
# the origin in rc-prepare.sh, and both the origin and an explicit --url in
# rc-clone-target.sh — goes through here so the parses can never drift apart.
# https://, ssh:// and scp-style (git@host:owner/repo) remotes are handled, with
# or without a trailing `.git`.
#
# The host is matched on its own, so a remote whose path this parser cannot
# reduce to owner/repo still names the host it points at. That covers a remote
# carrying extra path segments (a nested GitLab subgroup): the host is real and
# both callers ask about it first, while owner/repo stay blank because two
# segments cannot express it.
#
# A port is the one thing the host group refuses outright: `:` followed by
# digits leaves all three blank rather than yielding a host with the port shaved
# off. The port is part of the endpoint — `ghe.corp.net:8443` and
# `ghe.corp.net` are two different services — so dropping it would make unequal
# endpoints compare equal, which is exactly the identity confusion the host is
# checked for in the first place. It is refused rather than kept because
# `host:8443/o/r` cannot be told from scp-style `host:1234/repo`, where the
# digits are an owner; that ambiguity is worth resolving the day a caller can
# actually name a ported host.
#
# So a port, a filesystem path, and a bare hostname all leave the three blank.
# That is safe in both callers, but for different reasons, and each is a
# separate claim about a different consequence:
#   - rc-clone-target.sh compares the host to decide whether the checkout it is
#     standing in is the repository the caller named. A blank host never equals
#     the target host, so it neither enables the in-place fast path nor keeps
#     the gh path open: it can only ever cost the caller an optimisation, and a
#     ported remote losing that is the intended trade.
#   - rc-prepare.sh compares the host to pick a forge. A blank host matches
#     none, so the session degrades to forge=local — also safe, but a heavier
#     consequence than a lost fast path, since the review then covers the branch
#     diff rather than the pull request the caller asked about.
rc_remote_host="" rc_remote_owner="" rc_remote_repo=""
# shellcheck disable=SC2034 # the three are this function's return values, read
# by the scripts that source this library rather than anywhere inside it.
parse_remote() { # url -> sets rc_remote_host / rc_remote_owner / rc_remote_repo
	local host sep path
	rc_remote_host="" rc_remote_owner="" rc_remote_repo=""
	[[ "$1" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*://)?([^@/]+@)?([^/:]+)([:/]+)(.+)$ ]] || return 0
	# Read every group out before the next `=~`, which overwrites BASH_REMATCH.
	host="${BASH_REMATCH[3]}"
	sep="${BASH_REMATCH[4]}"
	path="${BASH_REMATCH[5]}"
	# Ambiguous port or digit-owner: refuse the whole parse, host included.
	[[ "$sep" == *:* ]] && [[ "$path" =~ ^[0-9]+(/|$) ]] && return 0
	rc_remote_host="$host"
	if [[ "$path" =~ ^([^/:]+)/([^/]+)$ ]]; then
		rc_remote_owner="${BASH_REMATCH[1]}"
		# `[^/]+` is greedy, so a trailing `.git` lands inside the repo group.
		rc_remote_repo="${BASH_REMATCH[2]%.git}"
	fi
}

# GNU timeout bounds every forge call, so a hung `gh`/`git` cannot stall a
# review indefinitely. macOS ships no `timeout` at all, and Homebrew's coreutils
# formula installs the GNU tools under a `g` prefix — the unprefixed names live
# in an un-PATHed libexec/gnubin. Accept either name so `brew install coreutils`
# is sufficient without PATH surgery.
#
# Called by the three scripts that make forge calls — rc-prepare.sh,
# rc-clone-target.sh, rc-post-comment-github.sh — and by nobody else. It used to
# run at source time, which gated all eight sourcing scripts on a dependency
# five of them never touch: on a macOS host without coreutils, evidence
# verification, consolidation, verdict extraction and comment rendering each
# printed a skip and did nothing, for want of a timeout none of them calls.
#
# Called EAGERLY at the top of those three, not lazily from rc_timeout below.
# rc-prepare.sh does not reach its first forge call until it has created the
# session directory and written several files into it; failing there would leave
# a half-built session behind a message that reads like nothing happened.
# Usage: rc_require_timeout   (call once, immediately after rc_trap_errors)
rc_require_timeout() {
	_RC_TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"
	if [[ -z "$_RC_TIMEOUT_BIN" ]]; then
		echo '{"status":"skip","message":"GNU timeout is required but not installed. Install it: brew install coreutils | apt-get install coreutils | dnf install coreutils"}'
		exit 0
	fi
}

# Run a command under the resolved GNU timeout binary. Exit status is the
# command's own, or 124 when the deadline is hit.
#
# _RC_TIMEOUT_BIN is deliberately left unset unless rc_require_timeout ran, so
# a caller that reaches here without requiring it dies on `set -u` rather than
# silently running the command unbounded — which is the failure this wrapper
# exists to prevent.
# Usage: rc_timeout <seconds> <command> [args...]
rc_timeout() {
	local secs="$1"
	shift
	"$_RC_TIMEOUT_BIN" "$secs" "$@"
}

# Read the value of a "- Key: value" or "Key: value" line from a file.
# Returns the first match's value, trimmed. Empty string if not found.
# Usage: value=$(rc_parse_kv "$file" "Forge")
rc_parse_kv() {
	local file="$1" key="$2"
	[[ -f "$file" ]] || return 0
	grep -m1 -E "^[-[:space:]]*${key}:" "$file" 2>/dev/null |
		sed -E "s/^[-[:space:]]*${key}:[[:space:]]*//" |
		sed -E 's/[[:space:]]+$//' || true
}

# Fail loudly. With pipefail set, a failing pipeline stage can otherwise abort
# a script (under set -e) or be missed with no trace, producing non-reproducible
# behavior. rc_trap_errors installs an ERR trap that reports the script and line
# of any UNHANDLED command failure to stderr (stdout stays reserved for the
# script's JSON/markdown payload). Errors you handle with `|| ...`, `if`, or
# `&&`/`||` lists are exempt per bash ERR semantics, so only genuine surprises
# print. Call rc_trap_errors once, immediately after sourcing this library.
rc_on_err() {
	local code="$1" line="$2" src="${3##*/}"
	echo "rc-error: ${src}:${line}: command failed (exit ${code}) under 'set -o pipefail'" >&2
}
rc_trap_errors() {
	set -o errtrace
	trap 'rc_on_err "$?" "$LINENO" "${BASH_SOURCE[0]}"' ERR
}
