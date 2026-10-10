# gitlab.sh — GitLab adapter for the preparation stages.
#
# Sourced by rc-prepare.sh when prepare-repo.sh detects `forge=gitlab`.
# Implements the same contract as github.sh; see that file and
# references/forge-adapters.md for what each function owes its caller.
# rc-post-comment-gitlab.sh sources it too, for rc_forge_glab and the gate
# alone: every glab call the poster makes goes through them.
#
# Every network call names its merge request explicitly: `-R host/group/project`
# for `glab mr`, `--hostname host` plus the URL-encoded project for `glab api`.
# Left unaddressed, glab resolves the project from the checkout's remotes —
# preferring `upstream` over origin — and the host from its own default, so a
# review could read another project's MR with the same number, on another
# instance. The host is the `forge_host` global prepare-repo.sh sets,
# defaulting to gitlab.com; the project is forge_owner/forge_repo. A function
# given no project makes no call and returns its empty result: there is no
# unaddressed glab call in this file.
#
# Credentials are the other half of addressing a host, and two helpers below
# own them: rc_forge_glab_admits decides whether a host may be contacted at
# all, and rc_forge_glab runs every glab call — the gate's own included — with
# only the tokens bound to that host. Nothing else in this file calls glab.
#
# Pipeline status is NOT reported yet: `rc_forge_fetch_pr` leaves
# pr_status_checks empty, so no STATUS CHECKS section is written and the
# Quality Gates phase degrades to "no CI data" — the same path a repository
# with no CI takes. Wiring it up means populating that one variable with
# `<name>: <grade>` lines whose grades use the vocabulary in
# prepare-emit.sh Section 16; nothing outside this file changes.
#
# Prior reviews are NOT reported either: rc_forge_fetch_reviews and
# rc_forge_fetch_review_comments are absent, so no prior-reviews.txt is
# written. GitHub's submitted review has no direct GitLab counterpart — an
# approval carries no body and no timestamp — so filling the first means
# choosing a source (approvals, or "approved this merge request" system
# notes), not translating a field. The conversation does not wait on them:
# prepare-context.sh fetches it whenever rc_forge_fetch_conversation exists.
#
# shellcheck shell=bash
# shellcheck disable=SC2034 # Sets globals the sourcing stage reads; standalone
# they look unused.

# shellcheck source=module/skills/review-council/scripts/lib/glab-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/../glab-env.sh"

# Gate outcomes for this process, keyed by host: empty when admitted, else the
# refusal. Declared global so it survives being sourced from inside a function.
declare -gA RC_FORGE_GL_GATE=()

# rc_forge_glab <secs> <host> <glab-arg>... — run glab against <host> under
# rc_timeout, without the variables that redirect it and with environment
# tokens only when they belong to <host>. The policy, and the measurements
# behind it, live in glab-env.sh.
rc_forge_glab() {
	local secs="$1" host="$2"
	local -a scrub
	shift 2
	# shellcheck disable=SC2312 # glab_env_scrub_args only prints; it has no failure to mask.
	mapfile -t scrub < <(glab_env_scrub_args "$host")
	rc_timeout "$secs" env "${scrub[@]}" glab "$@"
}

# rc_forge_glab_admits <host> <owner> <repo> — status 0 when a call may be
# made: the project is named, and the host is gitlab.com or passes the gate.
#
# rc-prepare.sh runs rc_forge_host_refusal before any adapter call under
# `--scope url`; this asks again rather than trusting that it ran, so an
# adapter function reached by any other path still cannot hand glab's token to
# a host the user never logged glab in to. The answer is kept per host for the
# process: asked per call, a self-hosted run checked five times, and one
# transient failure could empty a single artifact while its siblings were
# fetched. The cache fails closed: a network blip during the one check refuses
# that host for the rest of the process, and every artifact from it is empty
# rather than some. Called in the current shell, never in `$( )`, or the cache
# is lost with the subshell. gitlab.com is exempt: it is where an unbound token is
# issued, and a local gitlab.com remote reaches this file without the URL gate.
rc_forge_glab_admits() {
	local host="$1" owner="$2" repo="$3"
	[[ -n "$owner" ]] && [[ -n "$repo" ]] || return 1
	[[ "$host" != "gitlab.com" ]] || return 0
	if [[ -z "${RC_FORGE_GL_GATE[$host]+set}" ]]; then
		RC_FORGE_GL_GATE[$host]=$(rc_forge_host_refusal "$host")
	fi
	[[ -z "${RC_FORGE_GL_GATE[$host]}" ]]
}

rc_forge_fetch_pr() {
	local mr_number="$1" owner="$2" repo="$3" host="${forge_host:-gitlab.com}"
	local mr_json

	rc_forge_glab_admits "$host" "$owner" "$repo" || return 0
	mr_json=$(rc_forge_glab 30 "$host" mr view "$mr_number" -R "${host}/${owner}/${repo}" \
		--output json 2>/dev/null || echo "")

	[[ -n "$mr_json" ]] || return 0

	pr_title=$(echo "$mr_json" | jq -r '.title // ""')
	pr_body=$(echo "$mr_json" | jq -r '.description // ""')
	pr_base=$(echo "$mr_json" | jq -r '.target_branch // ""')
	pr_head=$(echo "$mr_json" | jq -r '.source_branch // ""')
	# The commit the posted marker names and rc-clone-target.sh materializes;
	# only a full commit id is kept.
	pr_head_sha=$(echo "$mr_json" | jq -r '.sha // ""')
	[[ "$pr_head_sha" =~ ^[0-9a-f]{40}$ ]] || pr_head_sha=""
	pr_url=$(echo "$mr_json" | jq -r '.web_url // ""')
	pr_state=$(echo "$mr_json" | jq -r '.state // ""')
}

# `--raw` is glab's "diff format that can be piped to commands": the file is
# parsed as a unified diff downstream, not shown to a person.
rc_forge_fetch_diff() {
	local mr_number="$1" owner="$2" repo="$3" out_file="$4" host="${forge_host:-gitlab.com}"

	: >"$out_file"
	rc_forge_glab_admits "$host" "$owner" "$repo" || return 0
	rc_forge_glab 30 "$host" mr diff "$mr_number" -R "${host}/${owner}/${repo}" --raw \
		2>/dev/null >"$out_file" || true
}

# <message> — why <host> must not be contacted, or nothing when it may.
# Optional capability, asked by rc-prepare.sh about a host the user named
# (`--scope url`) before any other forge call.
#
# glab sends its stored token (as PRIVATE-TOKEN) to whatever host it is pointed
# at, configured or not, so a pasted MR URL on a hostile host would collect the
# user's GitLab credentials on the first call. `glab auth status --hostname H`
# fails locally, without contacting H, when H is absent from glab's config —
# the case this exists to refuse. For a configured host it DOES contact H, with
# the stored token, so the gate is itself a network call to a host the user
# logged glab in to and chose to trust. Its exit status then depends on that
# call: an unreachable host fails (measured), so a blip refuses it — closed,
# not open. A host that rejects the token has been measured both ways (exit 1
# here with glab 1.102, exit 0 in another run), so nothing relies on the gate
# vouching for the token. An empty host is refused here rather than asked
# about: `--hostname ""` checks every configured host and can exit 0.
rc_forge_host_refusal() {
	local host="$1" status
	if ! command -v glab >/dev/null 2>&1; then
		echo "glab is not installed; it is required to review a GitLab merge request."
		return 0
	fi
	if [[ -n "$host" ]]; then
		if status=$(rc_forge_glab 15 "$host" auth status --hostname "$host" 2>&1); then
			return 0
		fi
		# glab's wording for a host absent from its config, the same string
		# scripts/lib/forge-gitlab.sh matches. Both cases refuse; the message
		# says which one the user has to fix.
		if [[ "$status" != *"has not been authenticated"* ]]; then
			echo "glab could not confirm a login for ${host} (unreachable, expired, or no token stored for it). See 'glab auth status --hostname ${host}'. Refusing to send GitLab credentials to a host glab could not confirm."
			return 0
		fi
	fi
	echo "glab is not logged in to ${host}; run 'glab auth login --hostname ${host}' first. Refusing to send GitLab credentials to a host glab is not configured for."
}

# Normalise a GitLab timestamp to UTC `YYYY-MM-DDTHH:MM:SSZ`, the shape GitHub
# returns. prepare-context.sh opens the re-review window by comparing
# created_at values as STRINGS, so a self-managed instance stamping `-04:00`
# beside a `.645Z` would order notes by wall clock, not by time. Fractions are
# dropped: the window is inclusive, so a reply in the verdict's own second is
# still kept.
#
# Anything unparseable becomes "", GitHub's own fallback for a missing
# timestamp. That sorts before every real one, so such a note can never be
# mistaken for the newest verdict, nor land inside a window it was not shown to
# belong to; the cost is that it is left out of the replies. Keeping the raw
# string instead would compare by accident of spelling.
#
# shellcheck disable=SC2016 # jq program, not shell expansion.
RC_FORGE_GL_UTC_JQ='
  def utc:
    (try (
      capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})T(?<t>[0-9]{2}:[0-9]{2}:[0-9]{2})([.][0-9]+)?(?<z>Z|(?<s>[-+])(?<h>[0-9]{2}):?(?<m>[0-9]{2}))$")
      | ("\(.d)T\(.t)Z" | fromdateiso8601)
        - (if .z == "Z" then 0
           else (if .s == "+" then 1 else -1 end) * ((.h | tonumber) * 3600 + (.m | tonumber) * 60)
           end)
      | todateiso8601
    ) catch null) // "";
'

# [{author, created_at, body}] — the MR's comment timeline, oldest first.
#
# Notes, not discussions: one row per comment, which is the shape the re-review
# filter reads. System notes ("added 1 commit", "approved this merge request")
# are GitLab narrating events, not participants replying, and are dropped.
# `sort=asc` is what keeps the list oldest first across pages — see github.sh
# for why the order is load-bearing.
#
# `glab api --paginate` output differs between glab versions: some merge every
# page into one array, others (1.102 among them) print each page as its own
# array back to back. Slurping and joining the arrays handles both. A page that
# is not an array (an error body mid-listing), or a call that fails partway,
# yields [] rather than a partial timeline: a truncated list can move the "last
# verdict" anchor.
rc_forge_fetch_conversation() {
	local mr_number="$1" owner="$2" repo="$3" host="${forge_host:-gitlab.com}" pages

	rc_forge_glab_admits "$host" "$owner" "$repo" || {
		echo "[]"
		return 0
	}
	# owner/repo are validated [A-Za-z0-9._-] segments, so `/` is the only
	# character the project path needs encoded.
	pages=$(rc_forge_glab 30 "$host" api --hostname "$host" --paginate \
		"projects/${owner//\//%2F}%2F${repo}/merge_requests/${mr_number}/notes?per_page=100&sort=asc&order_by=created_at" \
		2>/dev/null) || {
		echo "[]"
		return 0
	}

	jq -sc "${RC_FORGE_GL_UTC_JQ}"'
		if all(.[]; type == "array") then
			[add // [] | .[] | select(.system != true) | {
				author: (.author.username // "unknown"),
				created_at: ((.created_at // "") | utc),
				body: (.body // "")
			}]
		else [] end
	' <<<"$pages" 2>/dev/null || echo "[]"
}

# <login> — the account the council posts as, or empty. Optional capability;
# see the GitHub adapter for why identity is marker AND author. The re-review
# filter matches this username against the note authors rc-post-comment-gitlab.sh
# wrote as; the poster itself selects its own notes by numeric id. Takes no
# arguments by contract, so it asks the host of the project preparation
# resolved into forge_owner/forge_repo, and nothing without one.
rc_forge_current_user() {
	local host="${forge_host:-gitlab.com}" user_json
	rc_forge_glab_admits "$host" "${forge_owner:-}" "${forge_repo:-}" || return 0
	user_json=$(rc_forge_glab 15 "$host" api --hostname "$host" user 2>/dev/null) || return 0
	jq -r '.username // empty' <<<"$user_json" 2>/dev/null || echo ""
}
