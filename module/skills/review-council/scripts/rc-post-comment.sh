#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-post-comment.sh — ROUTER for Review Council PR-comment posting.
#
# Usage: rc-post-comment.sh <session_dir> [--send]
#
# Reads the detected Forge from tracking.md and execs the per-forge post script
# rc-post-comment-<forge>.sh (which owns rendering via rc-render-comment.sh, the
# auth gate, and the upsert policy). When no per-forge script exists for the
# detected forge, it execs the neutral renderer standalone as a render-only
# fallback (writes comment-body.md for manual posting; never writes upstream).
#
# This script never posts and never reads --send semantics; it only routes. The
# stable name/argument contract lets the orchestrator (SKILL.md Step 7) invoke a
# single script without building a per-forge name itself.

session_dir="${1:-}"
if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
	json_output "skip" "Session directory not found."
	exit 0
fi

tracking="$session_dir/tracking.md"
[[ -f "$tracking" ]] || { json_output "skip" "tracking.md not found."; exit 0; }

pr=$(rc_parse_kv "$tracking" "PR")
if [[ -z "$pr" || "$pr" == "none" ]]; then
	json_output "skip" "No PR in session; nothing to post to."
	exit 0
fi

forge=$(rc_parse_kv "$tracking" "Forge")
scripts_dir="$(dirname "$0")"
per_forge="${scripts_dir}/rc-post-comment-${forge}.sh"

if [[ -n "$forge" && -f "$per_forge" ]]; then
	exec bash "$per_forge" "$@"
fi

# No per-forge integration: render only, for manual posting.
exec bash "${scripts_dir}/rc-render-comment.sh" "$session_dir"
