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
#       Sets pr_title, pr_body, pr_base, pr_head, pr_url, pr_state and
#       pr_status_checks. Leaves them untouched when the PR cannot be read, so
#       the caller's "did we get a title" test still decides whether metadata
#       was obtained.
#
#   rc_forge_fetch_diff <pr> <owner> <repo> <out_file>
#       Writes the PR diff to out_file. A failure leaves the file empty rather
#       than aborting: the changeset falls back to the local range.
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

rc_forge_fetch_pr() {
	local pr_number="$1" owner="$2" repo="$3"
	local repo_flag pr_json
	repo_flag=$(build_repo_flag "$owner" "$repo")

	# shellcheck disable=SC2086 # repo_flag is a two-token flag or empty.
	pr_json=$(rc_timeout 30 gh pr view "$pr_number" $repo_flag \
		--json number,title,body,baseRefName,headRefName,url,state,statusCheckRollup \
		2>/dev/null || echo "")

	[[ -n "$pr_json" ]] || return 0

	pr_title=$(echo "$pr_json" | jq -r '.title // ""')
	pr_body=$(echo "$pr_json" | jq -r '.body // ""')
	pr_base=$(echo "$pr_json" | jq -r '.baseRefName // ""')
	pr_head=$(echo "$pr_json" | jq -r '.headRefName // ""')
	pr_url=$(echo "$pr_json" | jq -r '.url // ""')
	pr_state=$(echo "$pr_json" | jq -r '.state // ""')
	pr_status_checks=$(echo "$pr_json" | jq -r "$RC_FORGE_GH_STATUS_CHECKS_JQ")
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
# omit any of them: prepare-context.sh tests `declare -F` before calling and
# writes no artifact when the capability is absent. That is how a forge ships
# partial support without a stub that pretends to work.
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

# [{author, state, submitted_at, body}] — submitted reviews, oldest first.
rc_forge_fetch_reviews() {
	local pr_number="$1" owner="$2" repo="$3" reviews_json
	reviews_json=$(rc_timeout 30 gh api \
		"repos/${owner}/${repo}/pulls/${pr_number}/reviews" 2>/dev/null || echo "[]")

	jq -c '[.[]? | {
		author: (.user.login // "unknown"),
		state: (.state // ""),
		submitted_at: (.submitted_at // "unknown"),
		body: (.body // "")
	}]' <<<"$reviews_json" 2>/dev/null || echo "[]"
}

# [{file, line, author, body}] — inline review comments.
#
# `line` is null on a comment pinned to a line that later changed; GitHub keeps
# the original position in `original_line`. Falling back keeps such comments
# addressable instead of rendering them at line "?".
rc_forge_fetch_review_comments() {
	local pr_number="$1" owner="$2" repo="$3" comments_json
	comments_json=$(rc_timeout 30 gh api \
		"repos/${owner}/${repo}/pulls/${pr_number}/comments" 2>/dev/null || echo "[]")

	jq -c '[.[]? | {
		file: (.path // "?"),
		line: (.line // .original_line // "?"),
		author: (.user.login // "unknown"),
		body: (.body // "")
	}]' <<<"$comments_json" 2>/dev/null || echo "[]"
}

# [{author, created_at, body}] — the PR's issue-comment timeline.
#
# MUST be ordered oldest first. The re-review path takes `last` of the comments
# carrying the council's marker to find the most recent posted verdict, and
# selects replies by `created_at >= that`. An adapter returning newest-first
# would silently pick the FIRST verdict ever posted and sweep in every reply
# since. GitHub's issue-comments API is ascending by created_at.
rc_forge_fetch_conversation() {
	local pr_number="$1" owner="$2" repo="$3" conversation_json
	conversation_json=$(rc_timeout 30 gh api \
		"repos/${owner}/${repo}/issues/${pr_number}/comments" 2>/dev/null || echo "[]")

	jq -c '[.[]? | {
		author: (.user.login // "unknown"),
		created_at: (.created_at // ""),
		body: (.body // "")
	}]' <<<"$conversation_json" 2>/dev/null || echo "[]"
}
