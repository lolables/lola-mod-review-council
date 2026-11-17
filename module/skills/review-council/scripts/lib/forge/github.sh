# github.sh — GitHub adapter for the preparation stages.
#
# Sourced by rc-prepare.sh when prepare-repo.sh detects `forge=github`. Holds
# every GitHub-specific detail the stages would otherwise have to know: the CLI
# name, its flags, and the shape of what it returns. The stages see only the
# neutral contract below, so adding a forge is writing a sibling file rather
# than adding a branch to five stages. Mirrors the seam
# rc-post-comment-<forge>.sh already uses for posting; see
# references/forge-adapters.md.
#
# Contract:
#   rc_forge_fetch_pr <pr> <owner> <repo>
#       Sets pr_title, pr_body, pr_base, pr_head, pr_head_sha, pr_url, pr_state,
#       pr_status_checks and pr_created_at. Leaves them untouched when the PR
#       cannot be read, so the caller's "did we get a title" test still decides
#       whether metadata was obtained.
#
#   rc_forge_fetch_diff <pr> <owner> <repo> <out_file>
#       Writes the PR diff to out_file. A failure leaves the file empty rather
#       than aborting: the changeset falls back to the local range.
#
#   rc_forge_fetch_merge_base <pr> <owner> <repo> <head_sha>   (optional)
#       Prints the 40-hex merge-base the PR diff is taken against, or nothing.
#       Call after rc_forge_fetch_pr, whose baseRefOid it uses.
#
# Every function is a no-op-on-failure by design. Preparation must survive a
# forge that is down, rate-limiting, or refusing auth — the review continues
# against the diff with less context, which is the module's stated degradation
# rule.
#
# shellcheck shell=bash
# shellcheck disable=SC2034 # Sets globals the sourcing stage reads; standalone
# they look unused.

# Normalize `statusCheckRollup` into one `<name>: <grade>` line per check.
#
# The rollup is a union of two GraphQL node types and they share no field:
#
#   StatusContext (legacy commit statuses)  .context  .state
#   CheckRun      (GitHub Actions, Checks)  .name     .conclusion
#
# Reading `.context`/`.conclusion` only — as this did — is wrong for both. It
# dropped every CheckRun (no `.context` at all), which on an Actions repository
# is every check, leaving no STATUS CHECKS section, no ci-status.txt and the
# Quality Gates phase inert. And it read `.conclusion` off StatusContext nodes,
# which do not have one, so the legacy statuses that did survive were emitted
# with a null grade and graded `pending` no matter what they actually said.
#
# A CheckRun still running has a null conclusion and no `.state` to fall back
# to, so it interpolates as the literal `null` — which the CI table grades as
# pending. That is deliberate: dropping in-flight checks let a PR whose
# critical check was mid-flight read as fully green.
#
# Kept here rather than in scripts/jq/ deliberately: that directory holds the
# forge-neutral reducers every run uses, and this program is only meaningful
# against GitHub's rollup shape. A GitLab adapter's equivalent has nothing in
# common with it.
#
# shellcheck disable=SC2016 # $check_name is a jq binding, not a shell variable;
# single quotes are what keep it out of the shell's hands.
RC_FORGE_GH_STATUS_CHECKS_JQ='
  .statusCheckRollup[]?
  | (.context // .name) as $check_name
  | select($check_name != null and $check_name != "")
  | "\($check_name): \(.conclusion // .state)"
'

# When an inline comment becomes visible, shared by rc_forge_fetch_review_comments
# and rc_forge_fetch_conversation so the two cannot drift. GitHub stamps the
# inline comments of a pending review at DRAFT time; they are visible only once
# the review is submitted. `submitted_by_id` maps review id -> submitted_at off
# the reviews list (a pending review has none); `visible_at` runs on one inline
# comment and takes the later of its own created_at and its review's
# submitted_at, joined on pull_request_review_id. Both are
# YYYY-MM-DDTHH:MM:SSZ, so string max is time max. No matching review: own time.
RC_FORGE_GH_VISIBLE_AT_JQ='
  def submitted_by_id($reviews):
    $reviews | map(select(.submitted_at != null and .id != null) | {key: (.id | tostring), value: .submitted_at}) | from_entries;
  def visible_at($submitted):
    [(.created_at // ""), ($submitted[(.pull_request_review_id | tostring)] // "")] | max;
'

# The base branch's tip as rc_forge_fetch_pr read it, kept for
# rc_forge_fetch_merge_base. Adapter-private, and global so it survives being
# sourced from inside a function, as RC_FORGE_GL_GATE does in gitlab.sh.
declare -g RC_FORGE_GH_BASE_OID=""

rc_forge_fetch_pr() {
	local pr_number="$1" owner="$2" repo="$3"
	local repo_flag pr_json
	repo_flag=$(build_repo_flag "$owner" "$repo")
	RC_FORGE_GH_BASE_OID=""

	# shellcheck disable=SC2086 # repo_flag is a two-token flag or empty.
	pr_json=$(rc_timeout 30 gh pr view "$pr_number" $repo_flag \
		--json number,title,body,baseRefName,baseRefOid,headRefName,headRefOid,url,state,createdAt,statusCheckRollup \
		2>/dev/null || echo "")

	[[ -n "$pr_json" ]] || return 0

	pr_title=$(echo "$pr_json" | jq -r '.title // ""')
	pr_body=$(echo "$pr_json" | jq -r '.body // ""')
	pr_base=$(echo "$pr_json" | jq -r '.baseRefName // ""')
	pr_head=$(echo "$pr_json" | jq -r '.headRefName // ""')
	# The commit the posted marker names; only a full commit id is kept.
	pr_head_sha=$(echo "$pr_json" | jq -r '.headRefOid // ""')
	[[ "$pr_head_sha" =~ ^[0-9a-f]{40}$ ]] || pr_head_sha=""
	pr_url=$(echo "$pr_json" | jq -r '.url // ""')
	pr_state=$(echo "$pr_json" | jq -r '.state // ""')
	# When the PR was opened, by the forge's clock: the re-review snapshot when
	# the timeline is empty. prepare-context.sh validates its shape.
	pr_created_at=$(echo "$pr_json" | jq -r '.createdAt // ""')
	pr_status_checks=$(echo "$pr_json" | jq -r "$RC_FORGE_GH_STATUS_CHECKS_JQ")
	RC_FORGE_GH_BASE_OID=$(echo "$pr_json" | jq -r '.baseRefOid // ""')
	[[ "$RC_FORGE_GH_BASE_OID" =~ ^[0-9a-f]{40}$ ]] || RC_FORGE_GH_BASE_OID=""
}

rc_forge_fetch_diff() {
	local pr_number="$1" owner="$2" repo="$3" out_file="$4"
	local repo_flag
	repo_flag=$(build_repo_flag "$owner" "$repo")

	# shellcheck disable=SC2086 # repo_flag is a two-token flag or empty.
	rc_timeout 30 gh pr diff "$pr_number" $repo_flag 2>/dev/null >"$out_file" || true
}

# ---------------------------------------------------------------------------
# Optional capabilities
#
# Everything below enriches a review rather than defining it, so an adapter may
# omit any of them: the calling stage (prepare-context.sh, prepare-links.sh)
# tests `declare -F` before calling and writes no artifact when the capability
# is absent. That is how a forge ships partial support without a stub that
# pretends to work.
#
# Each returns NORMALIZED JSON on stdout, never the forge's own shape. That is
# the whole point of the seam — the stage that renders these files must not
# learn that GitHub spells an author `.user.login` and a comment's file
# `.path`, or the next forge has to impersonate GitHub's REST vocabulary to
# reuse the renderer.
#
# Failure is always an empty array (or empty output), never a non-zero exit:
# a forge that is down, rate-limiting or refusing auth costs the review its
# context, not its life.
# ---------------------------------------------------------------------------

# {title, body, state}, or no output when the issue cannot be read.
rc_forge_fetch_issue() {
	local issue_num="$1" owner="$2" repo="$3"
	local repo_flag issue_json
	repo_flag=$(build_repo_flag "$owner" "$repo")

	# shellcheck disable=SC2086 # repo_flag is a two-token flag or empty.
	issue_json=$(rc_timeout 30 gh issue view "$issue_num" $repo_flag \
		--json title,body,state 2>/dev/null || echo "")

	[[ -n "$issue_json" ]] || return 0

	jq -c '{title: (.title // ""), body: (.body // ""), state: (.state // "")}' \
		<<<"$issue_json" 2>/dev/null || true
}

# Every item of a GitHub list endpoint, as one JSON array in API order.
#
# A list endpoint answers one page at a time, 30 items unless asked for more,
# and `gh api` without --paginate returns that first page alone. A pull request
# with 110 comments was read as its oldest 30, so the reply window after the
# council's latest verdict held 25 of the 105 replies posted since, and none of
# the newest. --slurp gathers the pages into one outer array (gh refuses it
# beside --jq, so the merge happens here). A page that is not an array is an
# error body, and a failed call is a truncated list: either yields [] rather
# than the pages read so far, because a partial timeline can move the "latest
# verdict" anchor the re-review path selects replies by.
# A failure also returns non-zero, with the same [] on stdout: a caller merging
# several lists has to tell "this list is empty" from "this list was not read".
_rc_forge_gh_list() { # endpoint
	local pages
	pages=$(rc_timeout 60 gh api "$1?per_page=100" --paginate --slurp 2>/dev/null) || {
		echo "[]"
		return 1
	}
	jq -sc 'if length == 1 and (.[0] | type == "array") and all(.[0][]; type == "array") then .[0] | add // [] else error("not a page list") end' \
		<<<"$pages" 2>/dev/null || {
		echo "[]"
		return 1
	}
}

# [{author, state, submitted_at, body}] — submitted reviews, oldest first.
rc_forge_fetch_reviews() {
	local pr_number="$1" owner="$2" repo="$3" reviews_json
	reviews_json=$(_rc_forge_gh_list "repos/${owner}/${repo}/pulls/${pr_number}/reviews")

	jq -c '[.[]? | {
		author: (.user.login // "unknown"),
		state: (.state // ""),
		submitted_at: (.submitted_at // "unknown"),
		body: (.body // "")
	}]' <<<"$reviews_json" 2>/dev/null || echo "[]"
}

# [{file, line, author, created_at, body}] — inline review comments.
#
# `created_at` is when the comment became visible, not when it was drafted: see
# RC_FORGE_GH_VISIBLE_AT_JQ. A failed reviews list falls back to each comment's
# own time rather than dropping the comments.
#
# `line` is null on a comment pinned to a line that later changed; GitHub keeps
# the original position in `original_line`. Falling back keeps such comments
# addressable instead of rendering them at line "?".
rc_forge_fetch_review_comments() {
	local pr_number="$1" owner="$2" repo="$3" comments_json reviews_json
	comments_json=$(_rc_forge_gh_list "repos/${owner}/${repo}/pulls/${pr_number}/comments")
	# A failed list is [] on stdout, which is the documented fallback here.
	reviews_json=$(_rc_forge_gh_list "repos/${owner}/${repo}/pulls/${pr_number}/reviews") || true

	printf '%s\n%s\n' "$comments_json" "$reviews_json" | jq -sc "$RC_FORGE_GH_VISIBLE_AT_JQ"'
		submitted_by_id(.[1]) as $submitted
		| [.[0][]? | {
			file: (.path // "?"),
			line: (.line // .original_line // "?"),
			author: (.user.login // "unknown"),
			created_at: visible_at($submitted),
			body: (.body // "")
		}]' 2>/dev/null || echo "[]"
}

# [{author, bot, created_at, edited_at, body}] — the PR's conversation,
# oldest first: issue comments, submitted reviews and inline review comments in
# one timeline. `bot` is true for a GitHub App account (user.type "Bot").
# `channel` is issue, review or inline: the council posts its verdicts as issue
# comments only, so only an issue comment can be one.
#
# MUST be ordered oldest first. The re-review path takes `last` of the comments
# carrying the council's marker to find the most recent posted verdict, and
# opens the reply window from it. An adapter returning newest-first would
# silently pick the FIRST verdict ever posted and sweep in every reply since.
# The three lists are merged with a stable sort on created_at, so a same-second
# tie keeps issue, review, inline order.
#
# A review or inline comment posted after the verdict is a reply as surely as
# an issue comment is, and reading issues/<n>/comments alone never saw one. Each
# carries its origin as the FIRST line of its body — `[review: <STATE>]` or
# `[inline comment: <path>:<line>]` — so the envelope prepare-context.sh writes
# around it is unchanged. The path is the change author's and may hold a
# newline, which would start a line of its own in the body: one opening with
# the council's marker made the comment read as a verdict, so a reviewer's
# inline reply on that file was dropped. The origin line stays one line: every
# line separator in the path or line becomes a space.
#
# An empty COMMENTED review is the container GitHub creates for every batch of
# inline comments, which are already here, so it is dropped. An empty APPROVED
# or CHANGES_REQUESTED review says something by its state and is kept. A
# PENDING review is unsubmitted: no one else can see it, and it has no time.
#
# An inline comment of a pending review carries its DRAFT time in created_at and
# becomes visible only when the review is submitted. Each is timed at the later
# of its own created_at and its review's submitted_at (joined on
# pull_request_review_id), so a review drafted before the verdict and submitted
# after it does not lose its inline comments to the anchor. Both are
# YYYY-MM-DDTHH:MM:SSZ, so string max is time max. No matching review: own time.
#
# `edited_at` is updated_at when it is later than the time the entry became
# visible, else "": answering by editing an earlier comment moves nothing else.
# Submitting a drafted inline comment sets its updated_at to the review's
# submitted_at, which is its visible time, so that is not an edit. Reviews
# carry no updated_at.
#
# All three or nothing: one failed list yields [] for the whole timeline, for
# the reason _rc_forge_gh_list gives. The lists reach jq on stdin, never as
# arguments, which the kernel caps at 128 KiB each.
rc_forge_fetch_conversation() {
	local pr_number="$1" owner="$2" repo="$3" timeline_issues timeline_reviews timeline_inline
	timeline_issues=$(_rc_forge_gh_list "repos/${owner}/${repo}/issues/${pr_number}/comments") || {
		echo "[]"
		return 0
	}
	timeline_reviews=$(_rc_forge_gh_list "repos/${owner}/${repo}/pulls/${pr_number}/reviews") || {
		echo "[]"
		return 0
	}
	timeline_inline=$(_rc_forge_gh_list "repos/${owner}/${repo}/pulls/${pr_number}/comments") || {
		echo "[]"
		return 0
	}

	printf '%s\n%s\n%s\n' "$timeline_issues" "$timeline_reviews" "$timeline_inline" | jq -sc "$RC_FORGE_GH_VISIBLE_AT_JQ"'
		def edited_after($at): (.updated_at // "") as $u | if $u > $at then $u else "" end;
		.[0] as $issues | .[1] as $reviews | .[2] as $inline
		| submitted_by_id($reviews) as $submitted
		| [ ($issues[] | {
				author: (.user.login // "unknown"),
				bot: (.user.type == "Bot"),
				channel: "issue",
				created_at: (.created_at // ""),
				edited_at: edited_after(.created_at // ""),
				body: (.body // "")
			}),
			($reviews[]
				| select(.state != "PENDING" and .submitted_at != null)
				| select((.body // "") != "" or .state != "COMMENTED")
				| {
					author: (.user.login // "unknown"),
					bot: (.user.type == "Bot"),
					channel: "review",
					created_at: .submitted_at,
					edited_at: "",
					body: ("[review: \(.state)]\n"
						+ (if (.body // "") == "" then "(no body; review state: \(.state))" else .body end))
				}),
			($inline[] | visible_at($submitted) as $at | {
				author: (.user.login // "unknown"),
				bot: (.user.type == "Bot"),
				channel: "inline",
				created_at: $at,
				edited_at: edited_after($at),
				body: ("[inline comment: \(.path // "?" | tostring | gsub("[\r\n\u2028\u2029\u0085\u000b\u000c]"; " ")):\(.line // .original_line // "?" | tostring | gsub("[\r\n\u2028\u2029\u0085\u000b\u000c]"; " "))]\n" + (.body // ""))
			})
		] | sort_by(.created_at)
	' 2>/dev/null || echo "[]"
}

# <login> — a bare login naming the account the council posts as, or empty.
#
# Optional capability. Preparation uses it to tell the council's own verdict
# comment apart from a participant's reply that merely quotes it: the marker is
# public, so identity is marker AND author, exactly as the post script already
# requires before it will update or hide a comment. An adapter that omits this
# degrades to marker-only matching, which is disclosed in the artifact rather
# than assumed away.
#
# Empty on failure by design, like every other function here: an unauthenticated
# or rate-limited forge must not abort preparation.
rc_forge_current_user() {
	rc_timeout 15 gh api user --jq '.login' 2>/dev/null || echo ""
}

# [{path, target}] — every symlink in the tree at <head_sha>, target null when
# its blob could not be read or holds a NUL byte.
#
# Optional capability, and the one exception to "failure is empty output, exit
# 0": a partial list would judge a change against links that are not all there,
# so anything short of the complete list prints nothing and returns non-zero,
# and rc-check-symlinks.sh then discloses that it judged from the diff alone.
# That covers a tree GitHub reports as truncated (over 100,000 entries or 7 MB)
# and more links than REVIEW_COUNCIL_MAX_HEAD_LINKS (default 500): each link
# costs one blob request.
#
# The blob API returns base64 wrapped at 60 columns, which @base64d refuses
# until the line breaks are removed.
rc_forge_fetch_links() {
	local owner="$2" repo="$3" head_sha="$4"
	local max_links=500 tree_json link_rows row blob_sha blob_json entry entries=""
	[[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
	# Base 10 is forced: a leading zero would otherwise read as octal.
	[[ "${REVIEW_COUNCIL_MAX_HEAD_LINKS:-}" =~ ^[0-9]{1,18}$ ]] &&
		max_links=$((10#$REVIEW_COUNCIL_MAX_HEAD_LINKS))
	tree_json=$(rc_timeout 60 gh api "repos/${owner}/${repo}/git/trees/${head_sha}?recursive=1" 2>/dev/null) ||
		return 1
	link_rows=$(jq -c --argjson max "$max_links" '
		if type == "object" and .truncated == false and (.tree | type) == "array"
			and all(.tree[]; type == "object" and (.path | type) == "string" and (.mode | type) == "string")
		then [.tree[] | select(.mode == "120000") | {path, sha}]
			| if length <= $max then .[] else error("over the cap") end
		else error("incomplete tree") end' <<<"$tree_json" 2>/dev/null) || return 1
	while IFS= read -r row; do
		[[ -n "$row" ]] || continue
		blob_sha=$(jq -r '.sha' <<<"$row")
		[[ "$blob_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
		blob_json=$(rc_timeout 30 gh api "repos/${owner}/${repo}/git/blobs/${blob_sha}" 2>/dev/null) || blob_json=""
		entry=$(jq -c --arg blob "$blob_json" '{path, target: ([
			$blob | fromjson? | select(type == "object" and .encoding == "base64" and (.content | type) == "string")
			| .content | gsub("\\s"; "") | try @base64d catch empty
			| select(explode | all(. != 0))
		] | .[0])}' <<<"$row") || return 1
		entries+="$entry"$'\n'
	done <<<"$link_rows"
	jq -sc '.' <<<"$entries"
}

# <sha> — the merge-base the PR's diff is taken against, or no output.
#
# Optional capability (prepare-target.sh asks `declare -F`). GitHub's PR diff
# is the three-dot diff of its base and head, so the commit it starts from is
# the merge-base, which the compare endpoint reports as `merge_base_commit`
# (REST "Compare two commits": GET repos/{owner}/{repo}/compare/{base}...{head},
# which takes commit SHAs as well as refs). The base end is the baseRefOid read
# with the diff rather than the branch name: it is the tip that diff was cut
# from, and a SHA needs no URL encoding where a branch name may hold `#`, `%`
# or `?`. The merge base is on every page of the response, so no pagination.
# Like every other call in this file it goes through gh's own host and
# credentials, and its URL holds only validated segments and two commit ids.
#
# Empty unless both ends and the answer are full commit ids, on any failure.
rc_forge_fetch_merge_base() {
	local owner="$2" repo="$3" head_sha="$4" compare_json merge_base
	[[ "$RC_FORGE_GH_BASE_OID" =~ ^[0-9a-f]{40}$ && "$head_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
	compare_json=$(rc_timeout 30 gh api "repos/${owner}/${repo}/compare/${RC_FORGE_GH_BASE_OID}...${head_sha}" 2>/dev/null) ||
		return 0
	merge_base=$(jq -r 'if type == "object" then .merge_base_commit.sha // empty else empty end' \
		<<<"$compare_json" 2>/dev/null) || return 0
	[[ "$merge_base" =~ ^[0-9a-f]{40}$ ]] || return 0
	printf '%s' "$merge_base"
}
