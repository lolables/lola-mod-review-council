#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=module/skills/review-council/scripts/rc-lib.sh
source "$(dirname "$0")/rc-lib.sh"
rc_trap_errors     # report script:line on any unhandled failure (never silent)
rc_require_timeout # this script makes forge calls; fail before any side effect

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

# --- Forge URL hooks the renderer calls (empty => renderer uses plain spans) ---
#
# The renderer parses forge_web from the origin remote and leaves it empty
# when the host can't be determined (it holds zero forge knowledge - see
# rc-render-comment.sh). This script IS GitHub, so on that empty-host edge
# case it defaults forge_web to github.com/<owner>/<repo> here instead of
# degrading to plain code spans. $owner/$repo are read from session.txt below
# and are in scope by the time these hooks actually run (rc_render_comment_body
# is called after that read); posting itself already requires both to be set,
# so this default is only ever exercised alongside a real owner/repo.
rc_url_file() { # forge_web sha file line
	local web="$1" sha="$2" file="$3" line="$4" url
	[[ -n "$web" ]] || web="https://github.com/${owner}/${repo}"
	[[ -n "$web" && -n "$sha" ]] || {
		printf ''
		return
	}
	url="${web}/blob/${sha}/${file}"
	[[ -n "$line" && "$line" != "null" ]] && url="${url}#L${line}"
	printf '%s' "$url"
}
rc_url_commit() { # forge_web sha
	local web="$1" sha="$2"
	[[ -n "$web" ]] || web="https://github.com/${owner}/${repo}"
	[[ -n "$web" && -n "$sha" ]] || {
		printf ''
		return
	}
	printf '%s/commit/%s' "$web" "$sha"
}

# Maximum body GitHub accepts on an issue comment. This is a fact about the API,
# not a policy: how many comments a verdict may be spread across is the user's
# `Max comments` setting, read by the renderer from tracking.md. A body over this
# is rejected outright, after the entire review has already been paid for, which
# is why the renderer would rather trim than find out.
rc_comment_limit() {
	printf '65536'
}

# shellcheck source=module/skills/review-council/scripts/rc-render-comment.sh
source "$(dirname "$0")/rc-render-comment.sh"

# --- GitHub mechanics (each prints to stdout, non-zero on API error) ---
#
# These two listings are the ONLY selectors: every comment id and node id the
# write helpers below touch comes out of one of them, so filtering here filters
# every update, banner and hide. Both require marker AND author, because the
# marker alone proves nothing — see the RC_ACTOR block for why.
#
# Neither listing reads the marker out of the BODY. Above the marker sits each
# finding's evidence, a verbatim fenced quote of the source under review that the
# pull request author controls, and the marker key is public (see the RC_ACTOR
# block below) — so that quote can carry a whole counterfeit marker, key and all.
# Keying on the key is therefore no more proof of a marker than keying on the
# bare `part=` was. And jq's `capture` is `match` without the `g` flag: it returns
# the FIRST match in its subject, so a pattern searched over the body finds the
# counterfeit and never reaches the real one.
#
# What that costs: the comment is filed under a part it does not hold, so its own
# part is posted a second time while the original stays visible; and the
# `sha == sha_key` guard further down stops recognising the verdict this run just
# wrote, which the supersede sweep then folds away as outdated. Selecting on a
# bare `sha=<head>` anywhere in the body fails the mirror image: a PRIOR commit's
# verdict that quotes this commit's sha is adopted as part 1 of the current chain
# and overwritten in place, rather than banner-stamped and folded away.
#
# So both listings bind the LAST line that opens a marker and match only against
# that. Scanning back rather than taking the final line is what keeps an edited
# comment ours: a maintainer appending a note to the bot's comment pushes the
# marker off the end, and a listing reading only the final line would stop
# recognising it — posting the head again beside the edited copy, and never
# retiring that copy once the commit moves on, so the pull request would carry
# two live verdicts and keep one of them for good. The scan costs nothing against
# impersonation, because a counterfeit lives in the evidence and the evidence is
# always ABOVE the marker the renderer appends after the footer.
#
# That opening is `RC_MARKER_OPEN` from rc-lib.sh, shared with the re-review
# lookup in prepare-context.sh, which matches it the same way and for the same
# reason. Both patterns spell the marker out from that same opening, in the order
# rc-render-comment.sh emits the fields — one shape, so neither can keep working
# against a marker format the other has stopped recognising. `sha=` is one
# space-delimited token and NOT necessarily hex: an unresolvable HEAD renders
# `sha=unknown` (see sha_key below), and a capture insisting on hex would read
# nothing out of those markers — every part of a chain would fall back to part 1,
# and the sweep would read an empty sha for comments it had just posted.
RC_MARKER_LINE_JQ="((.body | split(\"\\n\") | map(select(startswith(\"${RC_MARKER_OPEN}\"))) | last) // \"\")"

# Every council comment already posted for THIS commit, one TSV row per part,
# ordered by part number. A verdict too large for one comment is chained across
# several, so "is it already posted?" is a list question, not a lookup: the
# re-render has to be matched against the previous run PART BY PART, or an
# updated part 2 would be written over part 1.
#
# Comments predating chaining carry no `part=` in their marker. They are part 1,
# which is what they were.
gh_list_sha_parts() { # owner repo pr sha actor
	rc_timeout 30 gh api "repos/$1/$2/issues/$3/comments?per_page=100" \
		--jq "[.[] | select((.user.login // \"\") == \"$5\")
			| ${RC_MARKER_LINE_JQ} as \$m
			| select(\$m | startswith(\"${RC_MARKER_OPEN}$4 \"))
			| [(.id | tostring), .node_id, ((\$m | capture(\"^${RC_MARKER_OPEN}[^ ]+ part=(?<p>[0-9]+)\").p) // \"1\")]]
			| sort_by(.[2] | tonumber)[] | @tsv"
}
gh_list_council() { # owner repo pr actor
	rc_timeout 30 gh api "repos/$1/$2/issues/$3/comments?per_page=100" \
		--jq ".[] | select((.user.login // \"\") == \"$4\")
			| ${RC_MARKER_LINE_JQ} as \$m
			| select(\$m != \"\")
			| [(.id | tostring), .node_id, ((\$m | capture(\"^${RC_MARKER_OPEN}(?<s>[^ ]+)\").s) // \"\")] | @tsv"
}
gh_get_body() { # owner repo id
	rc_timeout 30 gh api "repos/$1/$2/issues/comments/$3" --jq '.body'
}
gh_create() { # owner repo pr body_file
	local body
	body=$(cat "$4")
	rc_timeout 30 gh api "repos/$1/$2/issues/$3/comments" -f body="$body" --jq '.id'
}
gh_update() { # owner repo id body_file
	local body
	body=$(cat "$4")
	rc_timeout 30 gh api "repos/$1/$2/issues/comments/$3" -X PATCH -f body="$body" >/dev/null
}
gh_minimize() { # node_id
	# shellcheck disable=SC2016 # $id is a GraphQL variable bound by the -f id
	# argument below; the shell must not expand it.
	rc_timeout 30 gh api graphql \
		-f query='mutation($id:ID!){minimizeComment(input:{subjectId:$id,classifier:OUTDATED}){minimizedComment{isMinimized}}}' \
		-f id="$1" >/dev/null
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
tracking="$session_dir/tracking.md"
[[ -f "$tracking" ]] || {
	json_output "skip" "tracking.md not found."
	exit 0
}

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
# Built once here: every status envelope below reports the same paths. It lists
# every part, not just the head, so a caller told to post manually after a
# degrade or a refusal knows there is more than one file to paste.
body_payload=$(jq -n --arg b "$body_file" \
	--argjson parts "$RC_COMMENT_PARTS" \
	--argjson level "$RC_COMMENT_LEVEL" \
	--argjson dropped "$RC_COMMENT_DROPPED" \
	--args '{body_file:$b, parts:$parts, pare_level:$level, findings_dropped:$dropped, part_files:$ARGS.positional}' \
	"${RC_COMMENT_PART_FILES[@]}")

# Same GitHub default as the rc_url_* hooks above, for the supersede-notice
# URL built directly from RC_FORGE_WEB below (it doesn't go through a hook).
[[ -z "$RC_FORGE_WEB" ]] && RC_FORGE_WEB="https://github.com/${owner}/${repo}"

# --- Dry-run / degrade: render only ---
if [[ "$send" != "yes" ]] || ! command -v gh >/dev/null 2>&1; then
	msg="Rendered comment body (dry-run)."
	[[ "$send" == "yes" ]] && ! command -v gh >/dev/null 2>&1 && msg="gh not available; rendered body only; post manually."
	json_output "rendered" "$msg" "$body_payload"
	exit 0
fi

# --- Authorization gate: never write upstream without explicit opt-in. ---
if [[ "${REVIEW_COUNCIL_ALLOW_POST:-}" != "1" ]]; then
	json_output "confirm_required" "Not posting: REVIEW_COUNCIL_ALLOW_POST is not set. Show the rendered body to the user, obtain explicit confirmation (or honor standing auto-send), then re-run with REVIEW_COUNCIL_ALLOW_POST=1." \
		"$body_payload"
	exit 0
fi

# --- Who are we? Council comment identity is marker AND author. ---
#
# RC_MARKER_KEY is public: it ships in every verdict comment this tool has ever
# posted and verbatim in references/forge-adapters.md, so any PR participant can
# reproduce it. Were the marker the whole identity, an outsider's comment
# carrying it would be overwritten with the verdict body, or banner-stamped and
# hidden as outdated — destroying third-party content under a maintainer's write
# token. So both listings above also demand the comment be ours.
#
# Resolved here, after the posting gate, rather than at load time: dry-run and
# render-only runs must not require an authenticated `gh`, and this value is used
# by nothing before the API calls that follow.
#
# Fail closed on both failure shapes, and say which one happened — they need
# different actions from the user. gh's own stderr is left to flow through to
# the caller's stderr rather than discarded; only stdout must stay pure JSON.
#
# `GET /user` answers for a user-to-server token, so `.login` is always a human
# account: the `[bot]` logins GitHub Apps comment under cannot come back from
# it. An App installation token gets 403 here instead, which lands in the
# unresolved branch and refuses to post — deliberate, since accepting a
# caller-supplied identity would hand an attacker the selector this whole block
# exists to protect. The accepted shape is therefore plain account characters.
RC_ACTOR=$(rc_timeout 30 gh api user --jq '.login' || echo "")
rc_actor_re='^[A-Za-z0-9._-]+$'
if [[ -z "$RC_ACTOR" ]]; then
	json_output "error" "Could not resolve the authenticated GitHub account: \`gh api user\` returned nothing (check \`gh auth status\`; a GitHub App installation token cannot answer it). Not posting: selecting council comments by the marker alone is refused, because the marker is public and updating or hiding a participant's comment would destroy it." \
		"$body_payload"
	exit 0
fi
if [[ ! "$RC_ACTOR" =~ $rc_actor_re ]]; then
	json_output "error" "Resolved an authenticated account name that is not login-shaped: '${RC_ACTOR}'. Not posting: this value is interpolated into a jq string literal, and a login carrying a quote or backslash would escape it and rewrite the comment selection." \
		"$body_payload"
	exit 0
fi

# --- Upsert policy keyed on the reviewed commit SHA ---
sha_key="${RC_HEAD_SHA:-unknown}"
total="$RC_COMMENT_PARTS"
supersede_file="${session_dir}/.supersede-body.md"

# Mark a comment obsolete and fold it away. Banner first, original body below:
# the content stays readable, which matters when the obsolete verdict is what a
# maintainer was replying to. Already-marked comments are left alone so a repeat
# run does not stack banners.
gh_retire() { # id node_id current_url
	local id="$1" node="$2" url="$3" old_body
	old_body=$(gh_get_body "$owner" "$repo" "$id" 2>/dev/null || echo "")
	if [[ -n "$old_body" && "$old_body" != *"review-council:obsolete"* ]]; then
		{
			echo "> **Obsolete.** Superseded by the [current Review Council verdict](${url}) for commit \`${RC_SHORT_SHA}\`. <!-- review-council:obsolete -->"
			echo ""
			printf '%s' "$old_body"
		} >"$supersede_file"
		gh_update "$owner" "$repo" "$id" "$supersede_file" 2>/dev/null || true
	fi
	if [[ -n "$node" ]]; then
		gh_minimize "$node" 2>/dev/null || true
	fi
	return 0
}

# Replace the renderer's part-link placeholder in the head with links to the
# parts that were just posted.
#
# Substituted here rather than rendered, because the URLs do not exist until the
# comments do; the head is written last precisely so they are known by now.
#
# awk on an exact line match rather than sed: the replacement carries URLs, and
# `&` in a sed replacement expands to the whole match. The line arrives through
# the environment rather than `-v`, which processes backslash escapes.
gh_apply_part_links() { # head_body_file
	local file="$1" tmp="$1.links" links="" n grown
	for ((n = 2; n <= total; n++)); do
		links="${links:+$links, }[part ${n}](${part_url[$n]})"
	done
	links="_This verdict spans ${total} comments: ${links}._"
	RC_LINKS="$links" awk -v token="$RC_PART_LINKS_TOKEN" \
		'$0 == token { print ENVIRON["RC_LINKS"]; next } { print }' "$file" >"$tmp"
	# Substituting grows the body, and the renderer sized it against the limit
	# exactly. If the links push it over, the links go rather than the findings:
	# they are navigation, and the parts are adjacent in the thread regardless.
	grown=$(wc -c <"$tmp")
	if [[ "$grown" -le "$RC_COMMENT_LIMIT" ]]; then
		mv "$tmp" "$file"
	else
		rm -f "$tmp"
	fi
}

# Comments already posted for THIS commit, by part. A failed lookup must NOT be
# treated as "none" (that would post a duplicate) - abort instead.
if ! existing_tsv=$(gh_list_sha_parts "$owner" "$repo" "$pr" "$sha_key" "$RC_ACTOR"); then
	json_output "error" "Failed to query existing comments on PR #${pr}; not posting." \
		"$body_payload"
	exit 0
fi
# Is this verdict answering new discussion? prepare-context.sh writes
# pr-conversation.txt only when replies landed at or after our last verdict, so
# a non-empty file means this run has something to say back to someone.
#
# Such a run often sits at the SAME head sha as the verdict it replaces — that
# is the ordinary shape of a re-review asked for in a comment, where the
# argument moved and the code did not. The same-sha upsert below would then edit
# the old comment in place, and GitHub sends no notification for an edit: the
# answer to a maintainer's objection would land where nobody is looking.
#
# So supersede instead. Post fresh, retire the old, and let the thread show a
# reply where a reply belongs. Absent the file this is a plain re-run, and the
# idempotent path is what it should get.
supersede_all=0
if [[ -s "${session_dir}/pr-conversation.txt" ]]; then
	supersede_all=1
fi

declare -A existing_id=() existing_node=() part_url=() created_ids=()
if [[ "$supersede_all" -eq 0 ]]; then
	while IFS=$'\t' read -r e_id e_node e_part; do
		[[ -n "$e_id" ]] || continue
		existing_id["$e_part"]="$e_id"
		existing_node["$e_part"]="$e_node"
	done <<<"$existing_tsv"
fi

created=0
updated=0
unchanged=0
superseded=0

# TAIL FIRST, HEAD LAST. The head carries the verdict, the TL;DR and the links
# to the other parts, so it must not exist before the parts it points at do. A
# reader arriving between the two writes would otherwise follow a link to
# nothing, and a run that died halfway would leave a verdict summarising
# findings that were never posted. This is as close to atomic as the forge
# allows: the failure mode becomes orphan detail comments with no verdict, which
# is legible, rather than a verdict with no detail, which is not.
for ((n = total; n >= 1; n--)); do
	part_file="${RC_COMMENT_PART_FILES[n - 1]}"
	if [[ "$n" -eq 1 && "$total" -gt 1 ]]; then
		gh_apply_part_links "$part_file"
	fi
	cur="${existing_id[$n]:-}"
	if [[ -n "$cur" ]]; then
		# Same commit, same part: no-op when identical, else update in place.
		existing=$(gh_get_body "$owner" "$repo" "$cur" 2>/dev/null || echo "")
		rendered=$(cat "$part_file")
		if [[ "$existing" == "$rendered" ]]; then
			unchanged=$((unchanged + 1))
		elif gh_update "$owner" "$repo" "$cur" "$part_file"; then
			updated=$((updated + 1))
		else
			json_output "error" "Failed to update part ${n} of ${total} on PR #${pr}." \
				"$body_payload"
			exit 0
		fi
		new_id="$cur"
	else
		if ! new_id=$(gh_create "$owner" "$repo" "$pr" "$part_file"); then
			json_output "error" "Failed to create part ${n} of ${total} on PR #${pr}." \
				"$body_payload"
			exit 0
		fi
		created=$((created + 1))
		created_ids["$new_id"]=1
	fi
	part_url["$n"]="${RC_FORGE_WEB}/pull/${pr}#issuecomment-${new_id}"
done
new_url="${part_url[1]}"

# A verdict that now needs fewer comments than the last run leaves the surplus
# behind. Those parts carry THIS sha, so the prior-commit sweep below will not
# touch them; retired explicitly, or the pull request keeps showing findings the
# verdict no longer contains.
for n in "${!existing_id[@]}"; do
	[[ "$n" -gt "$total" ]] || continue
	gh_retire "${existing_id[$n]}" "${existing_node[$n]}" "$new_url"
	superseded=$((superseded + 1))
done

# Prior commits' comments, every part of them. Selected on "not this sha" rather
# than "not the comment I just wrote", because there are now several of those.
#
# Run AFTER the new parts land, never before: superseding first would open a
# window in which the pull request carries no verdict at all.
while IFS=$'\t' read -r id node sha; do
	[[ -z "$id" ]] && continue
	# Never retire what this run just posted. Those carry this sha too, so
	# without the exclusion a superseding run would fold away its own verdict
	# and leave the pull request with nothing but obsolete comments.
	[[ -n "${created_ids[$id]:-}" ]] && continue
	# Same sha is normally this run's own work and is left alone. When the
	# verdict is answering a conversation it is the comment being replaced.
	[[ "$sha" == "$sha_key" && "$supersede_all" -eq 0 ]] && continue
	gh_retire "$id" "$node" "$new_url"
	superseded=$((superseded + 1))
done < <(gh_list_council "$owner" "$repo" "$pr" "$RC_ACTOR" 2>/dev/null || true)

# One word for the whole verdict, chosen so a single-comment run reads exactly as
# it always did. A chain that created one part and updated another is reported as
# created, with the per-part counts alongside for anyone who needs them.
if [[ "$created" -gt 0 ]]; then
	action="created"
elif [[ "$updated" -gt 0 ]]; then
	action="updated"
else
	action="unchanged"
fi

posted_payload=$(jq -n --arg a "$action" --argjson s "$superseded" \
	--argjson p "$total" --argjson c "$created" --argjson u "$updated" --argjson n "$unchanged" \
	'{action:$a, superseded:$s, parts:$p, created:$c, updated:$u, unchanged:$n}')
msg="Comment ${action} on PR #${pr} (superseded ${superseded} prior)."
[[ "$total" -gt 1 ]] && msg="Verdict ${action} on PR #${pr} across ${total} comments (${created} created, ${updated} updated, ${unchanged} unchanged; superseded ${superseded} prior)."
json_output "posted" "$msg" "$posted_payload"
exit 0
