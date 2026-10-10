#!/usr/bin/env bash
# The GitLab half of the forge adapter contract: every `glab` invocation the
# batch scripts make lives here, behind the same forge_* functions
# forge-github.sh defines, answering the same questions in the same shapes.
# Source this file; do not execute it.
#
# Requires common.sh to be sourced first, for glab-env.sh. prs.sh and
# the entry scripts call these functions and so need it sourced before they
# run.
#
# Every function reads the globals resolve_target sets: FORGE_HOST (validated
# hostname, no port) and REPO (the project's full path, "group/sub/project").
# REPO is validated by resolve_project, which runs AFTER this file is sourced,
# so nothing here derives anything from it at source time: the project path is
# encoded at call time, inside the two helpers below.
#
# Only `glab api` is used. Its higher-level subcommands differ between glab
# releases (the MR note commands are marked experimental), while the REST API
# is versioned and documented.
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.
#
# shellcheck disable=SC2154 # REPO, FORGE_HOST and TARGET_PR are set by
# resolve_target in target.sh before any function here runs. `shellcheck -x`
# resolves them through the entry script, but `task lint` also checks this file
# standalone, where they look unassigned.

[[ -n "${_RC_FORGE_GITLAB_LOADED:-}" ]] && return 0
_RC_FORGE_GITLAB_LOADED=1

# _gl <glab args...> -> glab aimed at FORGE_HOST: without GITLAB_API_HOST or
# GLAB_ENABLE_CI_AUTOLOGIN, and without glab's environment tokens unless they
# belong to FORGE_HOST. Every glab call here goes through this; the policy and
# the glab behaviour behind it live in glab-env.sh (sourced by common.sh).
#
# Removed, an environment token leaves glab to fall back to the host's own
# stored login. An entry with no stored token is refused only when the server
# answers the anonymous call with 401, which GitLab does for the `user` lookup
# forge_auth_check makes after the auth-status gate.
_gl() {
	local -a scrub
	# shellcheck disable=SC2312 # glab_env_scrub_args only prints; it has no failure to mask.
	mapfile -t scrub < <(glab_env_scrub_args "$FORGE_HOST")
	env "${scrub[@]}" glab "$@"
}

# _gl_get <subpath> -> the JSON object glab returns for
# projects/<REPO>/<subpath>; non-zero when glab fails. The project path is
# URL-encoded as one segment (every "/" to %2F), which is how the API takes a
# project named by path rather than by numeric id.
_gl_get() {
	_gl api --hostname "$FORGE_HOST" "projects/${REPO//\//%2F}/$1" 2>/dev/null
}

# _gl_list <subpath> -> every page of a list endpoint merged into one JSON
# array; non-zero when glab fails or any page is not a JSON array. `--paginate`
# prints one array per page back to back, so the pages are slurped and added.
# glab's status is checked before jq runs so the failure does not depend on
# the caller having set pipefail.
#
# The type check is per page because glab can exit 0 with an error object as
# the body, and a caller iterating that object would walk its values as if
# they were list items. Failing the list hands the case to each caller's own
# stance on an unanswered lookup.
_gl_list() {
	local raw
	raw="$(_gl api --hostname "$FORGE_HOST" --paginate "projects/${REPO//\//%2F}/$1" 2>/dev/null)" || return 1
	printf '%s' "$raw" |
		jq -s 'map(if type == "array" then . else error("not an array") end) | add // []' 2>/dev/null
}

# forge_auth_check -> returns when glab is authenticated for FORGE_HOST, having
# set GITLAB_VIEWER_ID to the account's numeric user id; otherwise explains and
# exits 1. `exit`, not `return`, for the reason forge-github.sh gives.
#
# The id is what forge_comments_for compares note authors against: GitLab has
# no viewerDidAuthor, so "is this note ours" is answered here, once.
#
# Before anything contacts FORGE_HOST, the host must be present in glab's
# config. glab sends a GitLab token (as PRIVATE-TOKEN) to whatever --hostname
# it is given, configured or not, so a host taken from a pasted MR URL or a
# remote would otherwise collect the user's credentials on the first call.
# `glab auth status --hostname H` answers locally, without contacting H, when
# H is absent from glab's config; only a host the user has added with
# `glab auth login --hostname H` is ever contacted, and through _gl it gets
# only its own stored token or an environment token bound to it. Absent and
# present-but-failing are told apart by glab's own wording, so the operator is
# not sent to log in to a host that is merely unreachable. An empty host is
# refused rather than asked about: `--hostname ""` checks every configured
# host and can exit 0. The entry scripts call this before any other glab
# invocation.
#
# The gate has no timeout: scripts/ has no portable one (GNU timeout is not
# on macOS), so a configured host that hangs stalls the run here.
forge_auth_check() {
	local user status
	if [[ -z "$FORGE_HOST" ]]; then
		echo "No GitLab host to check glab's login for; refusing to call glab without one." >&2
		exit 1
	fi
	if ! status="$(_gl auth status --hostname "$FORGE_HOST" 2>&1)"; then
		if [[ "$status" == *"has not been authenticated"* ]]; then
			echo "${FORGE_HOST} is not in glab's config. Run 'glab auth login --hostname ${FORGE_HOST}' first (non-interactively: 'glab auth login --hostname ${FORGE_HOST} --stdin < tokenfile'); refusing to send GitLab credentials to a host glab is not configured for." >&2
		else
			echo "glab could not confirm a login for ${FORGE_HOST} (unreachable, expired, or no token stored for it). See 'glab auth status --hostname ${FORGE_HOST}'." >&2
		fi
		exit 1
	fi
	user="$(_gl api --hostname "$FORGE_HOST" user 2>/dev/null)" || user=""
	GITLAB_VIEWER_ID="$(printf '%s' "$user" | jq -r '.id // empty' 2>/dev/null || true)"
	[[ "$GITLAB_VIEWER_ID" =~ ^[1-9][0-9]*$ ]] || {
		echo "glab is not authenticated for ${FORGE_HOST}. Run 'glab auth login --hostname ${FORGE_HOST} --stdin < tokenfile' with a valid token." >&2
		exit 1
	}
}

# forge_collect_prs -> "<iid>\t<sha>" lines on stdout, newest first, and one of:
#
#   0  the lookup answered. Output may still be empty, which means the
#      project genuinely has no open merge requests.
#   1  an MR was named (TARGET_PR) and could not be read.
#   2  the listing itself failed.
#
# THIS IS THE ONE LOOKUP HERE THAT FAILS LOUD, for the reason forge-github.sh's
# forge_collect_prs spells out: an empty answer would read as "nothing to
# review", turning any outage into a silent success at zero work.
forge_collect_prs() {
	local raw
	if [[ -n "${TARGET_PR:-}" ]]; then
		raw="$(_gl_get "merge_requests/$TARGET_PR")" || return 1
		raw="$(printf '%s' "$raw" | jq -r '[.iid, .sha] | @tsv' 2>/dev/null)" || return 1
		[[ "$raw" =~ ^[0-9]+$'\t'[^[:space:]]+$ ]] || return 1
	else
		# glab's own stderr is left alone here, as gh's is on GitHub: it is the
		# only thing that tells the operator why the listing broke.
		raw="$(_gl api --hostname "$FORGE_HOST" --paginate \
			"projects/${REPO//\//%2F}/merge_requests?state=opened&per_page=100")" || return 2
		raw="$(printf '%s' "$raw" | jq -s -r \
			'add // [] | sort_by(.iid) | reverse | .[] | [.iid, .sha] | @tsv')" || return 2
	fi
	printf '%s' "$raw"
}

# forge_comments_for <mr> -> the MR's notes as a GitHub-shaped comment timeline
# ({comments: [...]}), or empty on failure. comments.sh holds the forgery
# boundary as jq over that shape, so normalising here lets it run unchanged.
#
# System notes ("added 1 commit", label changes) are GitLab's own bookkeeping
# and are dropped: no person wrote them.
#
# authorAssociation is MEMBER for every note because GitLab has no per-note
# association to report. That only removes requester_authorised's cheap first
# gate; forge_member_can_write is the real one, and it fails closed.
#
# GitLab cannot minimise a note, so isMinimized is read from a retire banner:
# the GitLab verdict poster is to prepend exactly this line as the FIRST line
# of a superseded verdict, as the council's GitHub poster minimises one. Only
# that exact first line counts, so a quote of the banner or the tag mentioned
# further down does not hide anything. Anyone can type the banner, but GitLab
# lets only a note's author, or a project Maintainer or Owner, edit a note. A
# Maintainer can so force a fresh review, or rewrite a verdict's marker sha to
# suppress one; that is authority a Maintainer already holds (they can merge),
# as GitHub trusts accounts that can edit others' comments. Anyone else can
# only hide their own note — which fails toward reviewing.
#
# createdAt is rewritten to whole-second UTC (…T13:52:36Z), the shape gh
# returns. GitLab adds milliseconds, and a self-managed instance answers in its
# configured time zone (…T09:52:36.645-04:00). The readers compare createdAt as
# a string against a `todate` window start and hand it to fromdateiso8601,
# which rejects both, so a stamp left as-is would put a verdict outside the
# rate-limit window by the offset.
#
# An unparseable stamp becomes "". GitLab sets created_at itself (only an
# owner or admin may backdate one), so this is a malformed server answer, not
# something a note's author can produce. "" sorts oldest, so a newer verdict
# still wins; as a verdict's time it makes every later request look newer,
# which fails toward reviewing. The one reader it errs open for is the
# rate-limit count, which skips a stamp it cannot place in the window.
forge_comments_for() {
	local viewer="${GITLAB_VIEWER_ID:-0}" notes
	# A non-numeric id would make --argjson fail and the whole payload vanish;
	# 0 matches no GitLab user, so "not ours" is the answer instead.
	[[ "$viewer" =~ ^[1-9][0-9]*$ ]] || viewer=0
	notes="$(_gl_list "merge_requests/$1/notes?per_page=100&sort=asc&order_by=created_at")" || return 0
	printf '%s' "$notes" | jq -c --argjson viewer "$viewer" '
		def utc_stamp:
			([ try (
				capture("^(?<b>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})$")
				| (if .z == "Z" then 0
				   else (.z[1:] | gsub(":"; "")) as $d
				     | (if .z[0:1] == "-" then -1 else 1 end)
				       * (($d[0:2] | tonumber) * 3600 + ($d[2:4] | tonumber) * 60)
				   end) as $offset
				| ((.b + "Z") | fromdateiso8601) - $offset
				| todate
			) ] | .[0]) // "";
		{comments: [ .[] | select((.system // false) | not)
		  | { author: {login: (.author.username // "")},
		      body: (.body // ""),
		      createdAt: ((.created_at // "") | utc_stamp),
		      viewerDidAuthor: ((.author.id // -1) == $viewer),
		      isMinimized: ((.body // "") | gsub("\r"; "") | split("\n")[0]
		                    | test("^> \\*\\*Obsolete\\.\\*\\* .*<!-- review-council:obsolete -->[ \t]*$")),
		      authorAssociation: "MEMBER" } ]}
	' 2>/dev/null || true
}

# forge_member_can_write <login> -> success when the account's effective role
# in the project (inherited group membership included) is Developer or above.
# FAILS CLOSED: any unreadable answer is a refusal, because the caller is
# deciding whether a stranger may spend the review budget.
#
# 30 (Developer) is the lowest role that can push. Reporter (20) and Guest (10)
# are refused, as GitHub's triage and read are.
forge_member_can_write() {
	local login="$1" id level
	# The login is interpolated into a query string. GitLab usernames are
	# letters, digits, ".", "_" and "-"; anything else is refused rather than
	# sent, and so is a leading "-" that glab could read as a flag.
	[[ "$login" =~ ^[A-Za-z0-9._-]+$ && "$login" != -* ]] || return 1
	# Not a project subpath, so not _gl_get.
	id="$(_gl api --hostname "$FORGE_HOST" "users?username=${login}" 2>/dev/null)" || return 1
	id="$(printf '%s' "$id" | jq -r '.[0].id // empty' 2>/dev/null)" || return 1
	[[ "$id" =~ ^[0-9]+$ ]] || return 1
	level="$(_gl_get "members/all/$id")" || return 1
	level="$(printf '%s' "$level" | jq -r '.access_level // empty' 2>/dev/null)" || return 1
	[[ "$level" =~ ^[0-9]+$ ]] && [[ "$level" -ge 30 ]]
}

# forge_commit_emails <mr> -> one commit-author email per line, or empty on
# failure.
forge_commit_emails() {
	local commits
	commits="$(_gl_list "merge_requests/$1/commits?per_page=100")" || return 0
	printf '%s' "$commits" | jq -r '.[].author_email // empty' 2>/dev/null || true
}

# forge_is_approved <mr> -> success when the MR is approved by somebody.
#
# `.approved` alone is not enough: with no approval rule configured GitLab
# reports approved:true and an empty approved_by, so every MR would read as
# approved. An approval needs the rule satisfied AND at least one approver.
# A failed lookup is not an approval, so a glab failure fails open to reviewing.
forge_is_approved() {
	local approvals
	approvals="$(_gl_get "merge_requests/$1/approvals")" || return 1
	printf '%s' "$approvals" |
		jq -e '.approved == true and ((.approved_by // []) | length > 0)' >/dev/null 2>&1
}

# forge_pr_meta <mr> -> {changedFiles, author: {is_bot}, files: [{path}]} in the
# shape effort_for reads from gh, or empty when the MR cannot be read.
#
# changes_count is a string, and "1000+" once GitLab stops counting; the "+"
# is dropped so a huge MR still reads as huge. A failed diffs lookup lists no
# files rather than discarding the count and author it has.
#
# Both documents reach jq on stdin, not as --argjson: diffs carry the patch
# text and can exceed the kernel's single-argument limit.
forge_pr_meta() {
	local mr diffs
	mr="$(_gl_get "merge_requests/$1")" || return 0
	diffs="$(_gl_list "merge_requests/$1/diffs?per_page=100")" || diffs='[]'
	printf '%s\n%s' "$mr" "$diffs" | jq -c -s '
		.[0] as $mr | .[1] as $diffs
		| { changedFiles: (($mr.changes_count // "0") | tostring | rtrimstr("+") | tonumber? // 0),
		    author: {is_bot: ($mr.author.bot // false)},
		    files: [ $diffs[]? | {path: .new_path} ] }
	' 2>/dev/null || true
}

# forge_post_comment <mr> <body-file> -> success when the note was posted.
#
# The body goes as a JSON document in a file (--input), not as a -f field: a
# verdict can exceed the kernel's 128 KiB single-argument limit, and a field
# that large fails with E2BIG before glab runs.
forge_post_comment() {
	local tmp rc=0
	tmp="$(mktemp)" || return 1
	if jq -Rs '{body: .}' <"$2" >"$tmp" 2>/dev/null; then
		_gl api --hostname "$FORGE_HOST" -X POST -H 'Content-Type: application/json' \
			--input "$tmp" "projects/${REPO//\//%2F}/merge_requests/$1/notes" >/dev/null 2>&1 || rc=$?
	else
		rc=1
	fi
	rm -f "$tmp"
	return "$rc"
}

# forge_pr_url <mr> -> the MR's web URL.
forge_pr_url() {
	printf 'https://%s/%s/-/merge_requests/%s' "$FORGE_HOST" "$REPO" "$1"
}

# forge_pr_label <mr> -> how this forge names an MR in display text.
forge_pr_label() {
	printf '!%s' "$1"
}
