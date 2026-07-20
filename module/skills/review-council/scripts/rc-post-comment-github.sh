#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors # report script:line on any unhandled failure (never silent)

# rc-post-comment-github.sh — GitHub implementation of Review Council comment
# posting. It defines the two URL-builder hooks, sources the neutral renderer,
# then owns the auth gate, the SHA-aware upsert POLICY, and the `gh` mechanics
# inline. Invoked by rc-post-comment.sh (the router) with the same args:
#
#   rc-post-comment-github.sh <session_dir> [--send]
#
# PR presence is guaranteed by the router; this script reads it for the API.
# Posting is gated by REVIEW_COUNCIL_ALLOW_POST=1 — a hard, machine-checkable
# backstop to the orchestrator's Step 7 confirmation.

MARKER_KEY="review-council:marker"

# --- Forge URL hooks the renderer calls (empty => renderer uses plain spans) ---
rc_url_file() { # forge_web sha file line
	local web="$1" sha="$2" file="$3" line="$4" url
	[[ -n "$web" && -n "$sha" ]] || { printf ''; return; }
	url="${web}/blob/${sha}/${file}"
	[[ -n "$line" && "$line" != "null" ]] && url="${url}#L${line}"
	printf '%s' "$url"
}
rc_url_commit() { # forge_web sha
	local web="$1" sha="$2"
	[[ -n "$web" && -n "$sha" ]] || { printf ''; return; }
	printf '%s/commit/%s' "$web" "$sha"
}

# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
source "$(dirname "$0")/rc-render-comment.sh"

# --- GitHub mechanics (each prints to stdout, non-zero on API error) ---
gh_find_by_sha() { # owner repo pr sha
	timeout 30 gh api "repos/$1/$2/issues/$3/comments?per_page=100" \
		--jq "[.[] | select((.body | contains(\"${MARKER_KEY}\")) and (.body | contains(\"sha=$4\"))) | .id] | first // empty"
}
gh_list_council() { # owner repo pr
	timeout 30 gh api "repos/$1/$2/issues/$3/comments?per_page=100" \
		--jq ".[] | select(.body | contains(\"${MARKER_KEY}\")) | [(.id | tostring), .node_id, ((.body | capture(\"sha=(?<s>[0-9a-fA-F]+)\").s) // \"\")] | @tsv"
}
gh_get_body() { # owner repo id
	timeout 30 gh api "repos/$1/$2/issues/comments/$3" --jq '.body'
}
gh_create() { # owner repo pr body_file
	timeout 30 gh api "repos/$1/$2/issues/$3/comments" -f body="$(cat "$4")" --jq '.id'
}
gh_update() { # owner repo id body_file
	timeout 30 gh api "repos/$1/$2/issues/comments/$3" -X PATCH -f body="$(cat "$4")" >/dev/null
}
gh_minimize() { # node_id
	timeout 30 gh api graphql \
		-f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
		-f id="$1" >/dev/null
}

# --- Args ---
session_dir="${1:-}"
send="no"
shift || true
while [[ $# -gt 0 ]]; do
	case "$1" in
	--send) send="yes"; shift ;;
	*) json_output "skip" "Unknown flag: $1"; exit 0 ;;
	esac
done

if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
	json_output "skip" "Session directory not found."
	exit 0
fi
tracking="$session_dir/tracking.md"
[[ -f "$tracking" ]] || { json_output "skip" "tracking.md not found."; exit 0; }

pr=$(rc_parse_kv "$tracking" "PR")
owner=$(rc_parse_kv "$session_dir/session.txt" "Owner")
repo=$(rc_parse_kv "$session_dir/session.txt" "Repo")
if [[ -z "$pr" || "$pr" == "none" ]]; then
	json_output "skip" "No PR in session; nothing to post to."
	exit 0
fi

# --- Render (sets RC_FORGE_WEB / RC_SHORT_SHA / RC_HEAD_SHA) ---
body_file="$session_dir/comment-body.md"
rc_render_comment_body "$session_dir" "$body_file"

# --- Dry-run / degrade: render only ---
if [[ "$send" != "yes" ]] || ! command -v gh >/dev/null 2>&1; then
	msg="Rendered comment body (dry-run)."
	[[ "$send" == "yes" ]] && ! command -v gh >/dev/null 2>&1 && msg="gh not available; rendered body only; post manually."
	json_output "rendered" "$msg" "$(jq -n --arg b "$body_file" '{body_file:$b}')"
	exit 0
fi

# --- Authorization gate: never write upstream without explicit opt-in. ---
if [[ "${REVIEW_COUNCIL_ALLOW_POST:-}" != "1" ]]; then
	json_output "confirm_required" "Not posting: REVIEW_COUNCIL_ALLOW_POST is not set. Show the rendered body to the user, obtain explicit confirmation (or honor standing auto-send), then re-run with REVIEW_COUNCIL_ALLOW_POST=1." \
		"$(jq -n --arg b "$body_file" '{body_file:$b}')"
	exit 0
fi

# --- Upsert policy keyed on the reviewed commit SHA ---
sha_key="${RC_HEAD_SHA:-unknown}"

# Comment already posted for THIS commit? A failed lookup must NOT be treated as
# "none" (that would post a duplicate) - abort instead.
if ! cur=$(gh_find_by_sha "$owner" "$repo" "$pr" "$sha_key"); then
	json_output "error" "Failed to query existing comments on PR #${pr}; not posting." \
		"$(jq -n --arg b "$body_file" '{body_file:$b}')"
	exit 0
fi

superseded=0
if [[ -n "$cur" ]]; then
	# Same commit already reviewed: no-op when identical, else update in place.
	existing=$(gh_get_body "$owner" "$repo" "$cur" 2>/dev/null || echo "")
	if [[ "$existing" == "$(cat "$body_file")" ]]; then
		action="unchanged"
	else
		if ! gh_update "$owner" "$repo" "$cur" "$body_file"; then
			json_output "error" "Failed to update comment on PR #${pr}." \
				"$(jq -n --arg b "$body_file" '{body_file:$b}')"
			exit 0
		fi
		action="updated"
	fi
else
	# New commit (or first review): create, then supersede prior commits'
	# comments (mark obsolete and hide as outdated).
	if ! new_id=$(gh_create "$owner" "$repo" "$pr" "$body_file"); then
		json_output "error" "Failed to create comment on PR #${pr}." \
			"$(jq -n --arg b "$body_file" '{body_file:$b}')"
		exit 0
	fi
	action="created"
	new_url="${RC_FORGE_WEB}/pull/${pr}#issuecomment-${new_id}"
	supersede_file="${session_dir}/.supersede-body.md"
	while IFS=$'\t' read -r id node sha; do
		[[ -z "$id" || "$id" == "$new_id" || "$sha" == "$sha_key" ]] && continue
		old_body=$(gh_get_body "$owner" "$repo" "$id" 2>/dev/null || echo "")
		if [[ -n "$old_body" && "$old_body" != *"review-council:obsolete"* ]]; then
			{
				echo "> **Obsolete.** Superseded by the [current Review Council verdict](${new_url}) for commit \`${RC_SHORT_SHA}\`. <!-- review-council:obsolete -->"
				echo ""
				printf '%s' "$old_body"
			} >"$supersede_file"
			gh_update "$owner" "$repo" "$id" "$supersede_file" 2>/dev/null || true
		fi
		[[ -n "$node" ]] && { gh_minimize "$node" 2>/dev/null || true; }
		superseded=$((superseded + 1))
	done < <(gh_list_council "$owner" "$repo" "$pr" 2>/dev/null || true)
fi

json_output "posted" "Comment ${action} on PR #${pr} (superseded ${superseded} prior)." \
	"$(jq -n --arg a "$action" --argjson s "$superseded" '{action:$a, superseded:$s}')"
exit 0
