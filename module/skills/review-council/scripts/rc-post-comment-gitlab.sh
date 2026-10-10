#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors     # report script:line on any unhandled failure (never silent)
rc_require_timeout # this script makes forge calls; fail before any side effect

# rc-post-comment-gitlab.sh — GitLab implementation of Review Council comment
# posting. It defines the three forge hooks, sources the neutral renderer and
# the GitLab adapter, then owns the auth gate, the SHA-aware upsert POLICY, and
# the `glab api` mechanics inline. Invoked by rc-post-comment.sh (the router)
# with the same args:
#
#   rc-post-comment-gitlab.sh <session_dir> [--send]
#
# It is a port of rc-post-comment-github.sh, section by section and with the
# same statuses and payloads; the reasoning behind each policy lives there and
# is not repeated here. What differs is GitLab's: notes instead of issue
# comments, a numeric author id instead of a login, a paginated listing, and no
# "minimize" — a retired note keeps its obsolete banner and stays expanded.
#
# Merge request presence is guaranteed by the router; this script reads it for
# the API. Posting is gated by REVIEW_COUNCIL_ALLOW_POST=1 — a hard,
# machine-checkable backstop to the orchestrator's Step 7 confirmation.
#
# Every glab call goes through the adapter's rc_forge_glab, addressed to the
# host recorded in session.txt, and only after rc_forge_glab_admits has let that
# host through. lib/forge/gitlab.sh explains what both protect against: glab
# hands environment and stored tokens to whatever host it is pointed at.

# --- Forge hooks the renderer calls (empty => renderer uses plain spans) ---
#
# GitLab puts a `/-/` separator before the route. The renderer builds forge_web
# from the host recorded in session.txt, else from the origin remote, and leaves
# it empty when neither yields a host; both hooks then degrade to a plain code
# span rather than guessing gitlab.com, because a self-hosted instance is the
# common case here, not the exception.
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

# The first line of a retired note, as a jq (Oniguruma) pattern. It must equal
# the one scripts/lib/forge-gitlab.sh reads as "collapsed"; the GitLab poster
# suite asserts the two (and its own copy) are one value.
RC_GL_OBSOLETE_RE='^> \*\*Obsolete\.\*\* .*<!-- review-council:obsolete -->[ \t]*$'

# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
source "$(dirname "$0")/rc-render-comment.sh"
# shellcheck source=module/skills/review-council/scripts/lib/forge/gitlab.sh
source "$(dirname "$0")/lib/forge/gitlab.sh"

# --- GitLab mechanics (each prints to stdout, non-zero on API error) ---
#
# All address the merge request in the globals forge_host, project_enc and mr,
# which are validated below before the first of these runs.
#
# Note bodies travel as a JSON file (`--input`), never as a `-f body=` field: a
# verdict may exceed the 128 KiB a single argv string is allowed, and GitLab's
# note limit is far above it.

# Every non-system note on the merge request, as one JSON array, oldest first.
# `--paginate` prints one array per page; they are joined here. A page that is
# not an array is an error body, and a failed call is a truncated list — both
# fail rather than return what was read, because the find-by-SHA lookup must
# never mistake "could not see" for "not posted yet".
gl_notes_json() {
	local pages
	pages=$(rc_forge_glab 30 "$forge_host" api --hostname "$forge_host" --paginate \
		"projects/${project_enc}/merge_requests/${mr}/notes?per_page=100&sort=asc&order_by=created_at") || return 1
	jq -sc 'if length > 0 and all(.[]; type == "array")
		then [add | .[] | select(.system | not)]
		else error("a notes page was not an array") end' <<<"$pages"
}

# The two listings below are the ONLY selectors, exactly as on GitHub: marker
# read from the last column-0 marker line (RC_MARKER_LINE_JQ), AND author id
# equal to the viewer's. The id comes in through --argjson and the sha through
# --arg, so neither is spliced into the program text. A note id that is not a
# number is skipped: it becomes part of an API path.
gl_list_sha_parts() { # sha
	local notes
	notes=$(gl_notes_json) || return 1
	jq -r --arg sha "$1" --argjson viewer "$viewer_id" \
		"[.[] | select(.author.id == \$viewer and (.id | type) == \"number\")
			| ${RC_MARKER_LINE_JQ} as \$m
			| select(\$m | startswith(\"${RC_MARKER_OPEN}\" + \$sha + \" \"))
			| [(.id | tostring), ((\$m | capture(\"^${RC_MARKER_OPEN}[^ ]+ part=(?<p>[0-9]+)\").p) // \"1\")]]
			| sort_by(.[1] | tonumber)[] | @tsv" <<<"$notes"
}
gl_list_council() {
	local notes
	notes=$(gl_notes_json) || return 1
	jq -r --argjson viewer "$viewer_id" \
		".[] | select(.author.id == \$viewer and (.id | type) == \"number\")
			| ${RC_MARKER_LINE_JQ} as \$m
			| select(\$m != \"\")
			| [(.id | tostring), ((\$m | capture(\"^${RC_MARKER_OPEN}(?<s>[^ ]+)\").s) // \"\")] | @tsv" <<<"$notes"
}
gl_get_body() { # note_id
	local note
	note=$(rc_forge_glab 30 "$forge_host" api --hostname "$forge_host" \
		"projects/${project_enc}/merge_requests/${mr}/notes/$1") || return 1
	jq -er '.body | strings' <<<"$note"
}
gl_create() { # body_file -> new note id
	local resp
	jq -Rs '{body: .}' <"$1" >"$req_file" || return 1
	resp=$(rc_forge_glab 30 "$forge_host" api --hostname "$forge_host" -X POST \
		"projects/${project_enc}/merge_requests/${mr}/notes" \
		--input "$req_file" -H 'Content-Type: application/json') || return 1
	jq -er '.id | select(type == "number") | tostring' <<<"$resp"
}
gl_update() { # note_id body_file
	jq -Rs '{body: .}' <"$2" >"$req_file" || return 1
	rc_forge_glab 30 "$forge_host" api --hostname "$forge_host" -X PUT \
		"projects/${project_enc}/merge_requests/${mr}/notes/$1" \
		--input "$req_file" -H 'Content-Type: application/json' >/dev/null
}

# --- Args ---
session_dir="${1:-}"
send="no"
shift || true
while [[ $# -gt 0 ]]; do
	case "$1" in
	--send)
		send="yes"
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
# The request body and banner files this script writes into the session hold
# nothing worth keeping once the run ends, on any path out of it.
req_file="${session_dir}/.note-request.json"
supersede_file="${session_dir}/.supersede-body.md"
trap 'rm -f "$req_file" "$supersede_file"' EXIT

tracking="$session_dir/tracking.md"
[[ -f "$tracking" ]] || {
	json_output "skip" "tracking.md not found."
	exit 0
}

mr=$(rc_parse_kv "$tracking" "PR")
owner=$(rc_parse_kv "$session_dir/session.txt" "Owner")
repo=$(rc_parse_kv "$session_dir/session.txt" "Repo")
if [[ -z "$mr" || "$mr" == "none" ]]; then
	json_output "skip" "No merge request in session; nothing to post to."
	exit 0
fi

# Refused before rendering, so nothing is written and nothing is posted.
gate_msg=$(rc_disposition_gate "$session_dir")
if [[ -n "$gate_msg" ]]; then
	json_output "error" "$gate_msg"
	exit 0
fi

# --- Render (sets RC_FORGE_WEB / RC_SHORT_SHA / RC_HEAD_SHA) ---
body_file="$session_dir/comment-body.md"
rc_render_comment_body "$session_dir" "$body_file"
body_payload=$(jq -n --arg b "$body_file" \
	--argjson parts "$RC_COMMENT_PARTS" \
	--argjson level "$RC_COMMENT_LEVEL" \
	--argjson dropped "$RC_COMMENT_DROPPED" \
	--args '{body_file:$b, parts:$parts, pare_level:$level, findings_dropped:$dropped, part_files:$ARGS.positional}' \
	"${RC_COMMENT_PART_FILES[@]}")

# --- Dry-run / degrade: render only ---
#
# The message carries what a person posting by hand needs: how many notes, and
# whether the verdict was trimmed and where the untrimmed report is.
if [[ "$send" != "yes" ]] || ! command -v glab >/dev/null 2>&1; then
	what="comment body for merge request !${mr}"
	[[ "$RC_COMMENT_PARTS" -gt 1 ]] && what="${what} in ${RC_COMMENT_PARTS} parts"
	msg="Rendered ${what} (dry-run)."
	[[ "$send" == "yes" ]] && msg="glab not available; rendered ${what} only; post manually, in order."
	[[ "$RC_COMMENT_LEVEL" -gt 0 ]] && msg="${msg} Trimmed to fit the note limit (level ${RC_COMMENT_LEVEL}, ${RC_COMMENT_DROPPED} finding(s) omitted); the full report is ${session_dir}/report.md."
	json_output "rendered" "$msg" "$body_payload"
	exit 0
fi

# --- Authorization gate: never write upstream without explicit opt-in. ---
if [[ "${REVIEW_COUNCIL_ALLOW_POST:-}" != "1" ]]; then
	json_output "confirm_required" "Not posting: REVIEW_COUNCIL_ALLOW_POST is not set. Show the rendered body to the user, obtain explicit confirmation (or honor standing auto-send), then re-run with REVIEW_COUNCIL_ALLOW_POST=1." \
		"$body_payload"
	exit 0
fi

# --- Where are we posting? Validated before any glab call. ---
#
# The host is the one preparation recorded (gitlab.com when none was), and it
# is where every call below sends the user's credentials, so it must be a plain
# DNS name: no port, no path, nothing glab could read as an option. Lowercased
# because the adapter compares it against the environment token's bound host.
# owner/repo and the MR number become API path segments.
forge_host=$(rc_parse_kv "$session_dir/session.txt" "Host")
[[ -z "$forge_host" || "$forge_host" == "none" ]] && forge_host="gitlab.com"
forge_host="${forge_host,,}"
if [[ ! "$forge_host" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$ ]]; then
	json_output "error" "The recorded forge host '${forge_host}' is not a plain host name; not posting." \
		"$body_payload"
	exit 0
fi
if [[ "$owner" == "none" || "$repo" == "none" ]] || ! project_path_ok "$owner" "$repo"; then
	json_output "error" "The recorded project '${owner}/${repo}' is not a safe GitLab project path; not posting." \
		"$body_payload"
	exit 0
fi
if [[ ! "$mr" =~ ^[0-9]+$ ]]; then
	json_output "error" "The recorded merge request '${mr}' is not a number; not posting." \
		"$body_payload"
	exit 0
fi
project_enc="${owner//\//%2F}%2F${repo}"
[[ -z "$RC_FORGE_WEB" ]] && RC_FORGE_WEB="https://${forge_host}/${owner}/${repo}"

# --- Credential gate: the host must be one glab is logged in to. ---
# Called in this shell, not in `$( )`, so the adapter's per-host cache holds.
if ! rc_forge_glab_admits "$forge_host" "$owner" "$repo"; then
	json_output "error" "${RC_FORGE_GL_GATE[$forge_host]:-Refusing to contact ${forge_host}.}" "$body_payload"
	exit 0
fi

# --- Who are we? Council note identity is marker AND author. ---
#
# See rc-post-comment-github.sh for why the marker alone is never enough, and
# why this is resolved after the posting gate. GitLab names authors by a
# numeric id that a rename cannot change, so the selectors compare that, and
# only a positive integer is accepted: it is the one value every listing filter
# depends on. A response without a username is not a user object, whatever
# else it carries, and is refused the same way.
user_json=$(rc_forge_glab 30 "$forge_host" api --hostname "$forge_host" user || echo "")
viewer_id=$(jq -r 'select((.id | type) == "number" and (.username | type) == "string" and .username != "") | .id' \
	<<<"$user_json" 2>/dev/null || echo "")
if [[ -z "$user_json" ]]; then
	json_output "error" "Could not resolve the authenticated GitLab account: \`glab api user\` returned nothing (check \`glab auth status --hostname ${forge_host}\`). Not posting: selecting council notes by the marker alone is refused, because the marker is public and updating a participant's note would destroy it." \
		"$body_payload"
	exit 0
fi
if [[ ! "$viewer_id" =~ ^[1-9][0-9]*$ ]]; then
	json_output "error" "\`glab api user\` on ${forge_host} did not return a user with a numeric id and a username. Not posting: the author id is what tells the council's notes from anyone else's." \
		"$body_payload"
	exit 0
fi

# --- Upsert policy keyed on the reviewed commit SHA ---
sha_key="${RC_HEAD_SHA:-unknown}"
total="$RC_COMMENT_PARTS"

# Mark a note obsolete. Banner first, original body below, the banner line
# byte-identical to GitHub's: the batch status scripts read exactly that first
# line as "collapsed". GitLab has no way to hide a note, and deleting one would
# take a maintainer's reply context with it, so the banner is the whole of it.
#
# A note counts as already retired only when its FIRST line, carriage returns
# dropped, is that banner — the test scripts/lib/forge-gitlab.sh applies, with
# the same pattern. Searching the body for the tag would skip a verdict whose
# evidence quotes it, and with no way to hide a note that verdict would stay
# live on the merge request for good. Already-retired notes are left alone so
# a repeat run does not stack banners.
#
# Status non-zero when the note could not be read or rewritten, so the caller
# counts it as a failure rather than as superseded.
gl_retire() { # id current_url
	local id="$1" url="$2" old_body
	old_body=$(gl_get_body "$id") || return 1
	if jq -en --arg b "$old_body" --arg re "$RC_GL_OBSOLETE_RE" \
		'$b | gsub("\r"; "") | split("\n")[0] | test($re)' >/dev/null; then
		return 0
	fi
	{
		echo "> **Obsolete.** Superseded by the [current Review Council verdict](${url}) for commit \`${RC_SHORT_SHA}\`. <!-- review-council:obsolete -->"
		echo ""
		printf '%s' "$old_body"
	} >"$supersede_file"
	gl_update "$id" "$supersede_file"
}

# Replace the renderer's part-link placeholder in the head with links to the
# parts just posted; dropped whole if they would push the head over the limit.
# awk with the line from the environment, for the reasons given in
# rc-post-comment-github.sh.
gl_apply_part_links() { # head_body_file
	local file="$1" tmp="$1.links" links="" n grown
	for ((n = 2; n <= total; n++)); do
		links="${links:+$links, }[part ${n}](${part_url[$n]})"
	done
	links="_This verdict spans ${total} comments: ${links}._"
	RC_LINKS="$links" awk -v token="$RC_PART_LINKS_TOKEN" \
		'$0 == token { print ENVIRON["RC_LINKS"]; next } { print }' "$file" >"$tmp"
	grown=$(wc -c <"$tmp")
	if [[ "$grown" -le "$RC_COMMENT_LIMIT" ]]; then
		mv "$tmp" "$file"
	else
		rm -f "$tmp"
	fi
}

# Notes already posted for THIS commit, by part. A failed lookup must NOT be
# treated as "none" (that would post a duplicate) - abort instead.
if ! existing_tsv=$(gl_list_sha_parts "$sha_key"); then
	json_output "error" "Failed to query existing notes on merge request !${mr}; not posting." \
		"$body_payload"
	exit 0
fi
# Answering new discussion: post fresh and retire the old rather than edit in
# place, because GitLab, like GitHub, notifies nobody of an edit.
supersede_all=0
if [[ -s "${session_dir}/pr-conversation.txt" ]]; then
	supersede_all=1
fi

declare -A existing_id=() part_url=() created_ids=()
if [[ "$supersede_all" -eq 0 ]]; then
	while IFS=$'\t' read -r e_id e_part; do
		[[ -n "$e_id" ]] || continue
		existing_id["$e_part"]="$e_id"
	done <<<"$existing_tsv"
fi

created=0
updated=0
unchanged=0
superseded=0
retire_failed=0

# TAIL FIRST, HEAD LAST: the head links the other parts, so it is written once
# they exist, and a run that dies partway leaves no verdict over missing detail.
for ((n = total; n >= 1; n--)); do
	part_file="${RC_COMMENT_PART_FILES[n - 1]}"
	if [[ "$n" -eq 1 && "$total" -gt 1 ]]; then
		gl_apply_part_links "$part_file"
	fi
	cur="${existing_id[$n]:-}"
	if [[ -n "$cur" ]]; then
		# Same commit, same part: no-op when identical, else update in place.
		existing=$(gl_get_body "$cur" 2>/dev/null || echo "")
		rendered=$(cat "$part_file")
		if [[ "$existing" == "$rendered" ]]; then
			unchanged=$((unchanged + 1))
		elif gl_update "$cur" "$part_file"; then
			updated=$((updated + 1))
		else
			json_output "error" "Failed to update part ${n} of ${total} on merge request !${mr}." \
				"$body_payload"
			exit 0
		fi
		new_id="$cur"
	else
		if ! new_id=$(gl_create "$part_file"); then
			json_output "error" "Failed to create part ${n} of ${total} on merge request !${mr}." \
				"$body_payload"
			exit 0
		fi
		created=$((created + 1))
		created_ids["$new_id"]=1
	fi
	part_url["$n"]="${RC_FORGE_WEB}/-/merge_requests/${mr}#note_${new_id}"
done
new_url="${part_url[1]}"

# Surplus parts on this sha: the prior-commit sweep below will not reach them.
for n in "${!existing_id[@]}"; do
	[[ "$n" -gt "$total" ]] || continue
	if gl_retire "${existing_id[$n]}" "$new_url"; then
		superseded=$((superseded + 1))
	else
		retire_failed=$((retire_failed + 1))
	fi
done

# Prior commits' notes, every part of them — AFTER the new parts land, never
# before, and never the notes this run just created. Best-effort: the verdict
# is already posted, so a failed listing retires nothing rather than failing,
# and a note that could not be retired is reported in retire_failed instead.
while IFS=$'\t' read -r id sha; do
	[[ -z "$id" ]] && continue
	[[ -n "${created_ids[$id]:-}" ]] && continue
	[[ "$sha" == "$sha_key" && "$supersede_all" -eq 0 ]] && continue
	if gl_retire "$id" "$new_url"; then
		superseded=$((superseded + 1))
	else
		retire_failed=$((retire_failed + 1))
	fi
done < <(gl_list_council 2>/dev/null || true)

if [[ "$created" -gt 0 ]]; then
	action="created"
elif [[ "$updated" -gt 0 ]]; then
	action="updated"
else
	action="unchanged"
fi

# retire_failed is GitLab's addition to GitHub's payload: with no way to hide a
# note, one that could not be bannered is a live stale verdict the caller must
# hear about. The status stays `posted` because the new verdict did post.
posted_payload=$(jq -n --arg a "$action" --argjson s "$superseded" \
	--argjson p "$total" --argjson c "$created" --argjson u "$updated" --argjson n "$unchanged" \
	--argjson f "$retire_failed" \
	'{action:$a, superseded:$s, parts:$p, created:$c, updated:$u, unchanged:$n, retire_failed:$f}')
msg="Note ${action} on merge request !${mr} (superseded ${superseded} prior)."
[[ "$total" -gt 1 ]] && msg="Verdict ${action} on merge request !${mr} across ${total} notes (${created} created, ${updated} updated, ${unchanged} unchanged; superseded ${superseded} prior)."
[[ "$retire_failed" -gt 0 ]] && msg="${msg} ${retire_failed} prior note(s) could not be retired and still read as current."
json_output "posted" "$msg" "$posted_payload"
exit 0
