#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-post-comment-gitlab.sh — GitLab RENDERER for the Review Council comment.
#
#   rc-post-comment-gitlab.sh <session_dir> [--send]
#
# It defines the three forge hooks — the two URL builders and the note size
# limit — sources the neutral renderer, and stops there. It never writes
# upstream, with or without --send.
#
# That is deliberate, and it is the whole reason this file exists rather than
# letting the router fall through to `rc-render-comment.sh` standalone. The
# hooks live in per-forge POST scripts, so without one there is nowhere to
# declare GitLab's limit, and a GitLab review would render deep-link-free bodies
# against no size budget at all. With it, GitLab gets correct permalinks and the
# paring ladder, and exercises the same hook path GitHub does — which is what
# makes "the limit is per-forge" a testable claim rather than a comment.
#
# Posting is not implemented: the upsert, supersede and identity policy in
# rc-post-comment-github.sh has no `glab` equivalent yet, and a half-built
# poster that creates a comment but cannot find its own on the next run leaves
# duplicate verdicts on the merge request. Until that lands, the body is
# rendered for manual posting. See references/forge-adapters.md.

# --- Forge hooks the renderer calls (empty => renderer uses plain spans) ---
#
# GitLab puts a `/-/` separator before the route. The renderer parses forge_web
# from the origin remote and leaves it empty when the host cannot be determined,
# which covers self-hosted instances behind an unparseable remote; both hooks
# degrade to a plain code span rather than guessing gitlab.com, because a
# self-hosted instance is the common case here, not the exception.
rc_url_file() { # forge_web sha file line
	local web="$1" sha="$2" file="$3" line="$4" url
	[[ -n "$web" && -n "$sha" ]] || {
		printf ''
		return
	}
	url="${web}/-/blob/${sha}/${file}"
	[[ -n "$line" && "$line" != "null" ]] && url="${url}#L${line}"
	printf '%s' "$url"
}
rc_url_commit() { # forge_web sha
	local web="$1" sha="$2"
	[[ -n "$web" && -n "$sha" ]] || {
		printf ''
		return
	}
	printf '%s/-/commit/%s' "$web" "$sha"
}

# Maximum length of a GitLab note. Roughly fifteen times GitHub's, so the same
# review that has to be pared for GitHub posts whole here — which is the point
# of resolving the limit per forge instead of hardcoding the smallest one.
# A self-hosted instance behind a proxy that imposes something smaller is what
# the `Comment limit` configuration key overrides.
rc_comment_limit() {
	printf '1000000'
}

# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
source "$(dirname "$0")/rc-render-comment.sh"

# --- Args ---
session_dir="${1:-}"
shift || true
while [[ $# -gt 0 ]]; do
	case "$1" in
	--send)
		# Accepted and ignored: the router passes the caller's flags through
		# verbatim, and rejecting it here would turn "GitLab cannot post yet"
		# into "you used the wrong flag".
		shift
		;;
	*)
		json_output "skip" "Unknown flag: $1"
		exit 0
		;;
	esac
done

if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
	json_output "skip" "Session directory not found."
	exit 0
fi
tracking="$session_dir/tracking.md"
[[ -f "$tracking" ]] || {
	json_output "skip" "tracking.md not found."
	exit 0
}

mr=$(rc_parse_kv "$tracking" "PR")
if [[ -z "$mr" || "$mr" == "none" ]]; then
	json_output "skip" "No merge request in session; nothing to post to."
	exit 0
fi

body_file="$session_dir/comment-body.md"
rc_render_comment_body "$session_dir" "$body_file"

payload=$(jq -n --arg b "$body_file" \
	--argjson parts "$RC_COMMENT_PARTS" \
	--argjson level "$RC_COMMENT_LEVEL" \
	--argjson dropped "$RC_COMMENT_DROPPED" \
	--args '{body_file:$b, parts:$parts, pare_level:$level, findings_dropped:$dropped, part_files:$ARGS.positional}' \
	"${RC_COMMENT_PART_FILES[@]}")
msg="Rendered comment body for merge request !${mr}; GitLab posting is not implemented - post it manually."
[[ "$RC_COMMENT_PARTS" -gt 1 ]] && msg="Rendered comment body for merge request !${mr} in ${RC_COMMENT_PARTS} parts; GitLab posting is not implemented - post them in order, manually."
[[ "$RC_COMMENT_LEVEL" -gt 0 ]] && msg="${msg} Trimmed to fit the note limit (level ${RC_COMMENT_LEVEL}, ${RC_COMMENT_DROPPED} finding(s) omitted); the full report is in the run artifacts."
json_output "rendered" "$msg" "$payload"
exit 0
