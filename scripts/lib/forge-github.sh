#!/usr/bin/env bash
# The GitHub half of the forge adapter contract: every `gh` invocation the batch
# scripts make lives here, behind forge_* functions that prs.sh and the entry
# scripts call. Source this file; do not execute it.
#
# Requires nothing else to be sourced first, but prs.sh and the entry scripts
# call these functions and so need it sourced before they run.
#
# Every function reads the global REPO ("owner/name"), which resolve_target
# sets. Output shapes are the contract: another forge's adapter answers the
# same questions in the same shapes.
#
# shellcheck shell=bash
# shellcheck disable=SC2250 # Bare $var, as every other shell source here writes
# it. Enabling the braces-always style in these files would make them the only
# ones of their kind in the tree; consistency is worth more than the check.
#
# shellcheck disable=SC2154 # REPO and TARGET_PR are set by resolve_target in
# target.sh before any function here runs. `shellcheck -x` resolves them through
# the entry script, but `task lint` also checks this file standalone, where they
# look unassigned.

[[ -n "${_RC_FORGE_GITHUB_LOADED:-}" ]] && return 0
_RC_FORGE_GITHUB_LOADED=1

# forge_auth_check -> returns when gh is authenticated; otherwise explains and
# exits 1. `exit`, not `return`: this runs at the top level of an entry script,
# where it is the same unconditional stop require_commands makes.
forge_auth_check() {
	gh auth status >/dev/null 2>&1 || {
		echo "gh is not authenticated. Run 'gh auth login' (or set GITHUB_TOKEN)." >&2
		exit 1
	}
}

# forge_collect_prs -> "<number>\t<headRefOid>" lines on stdout, newest first,
# and one of:
#
#   0  the lookup answered. Output may still be empty, which means the
#      repository genuinely has no open PRs.
#   1  a PR was named (TARGET_PR) and could not be read.
#   2  the listing itself failed.
#
# THIS IS THE ONE LOOKUP HERE THAT FAILS LOUD. Everywhere else an unanswered gh
# call means "review it". Here an empty answer is indistinguishable from "there
# is nothing to review", so failing open would turn a typo'd --repo, a 502 or a
# secondary rate limit into "everything is reviewed, nothing to do" — a silent
# success at zero work, which for a tool that spends money and comments in
# public is the worst outcome available.
forge_collect_prs() {
	local raw
	if [[ -n "${TARGET_PR:-}" ]]; then
		raw="$(gh pr view "$TARGET_PR" --repo "$REPO" \
			--json number,headRefOid --jq '[.number, .headRefOid] | @tsv' 2>/dev/null)" || return 1
		[[ -n "$raw" ]] || return 1
	else
		# gh's own stderr is left alone here: when this fails the operator is
		# about to be told the listing broke, and gh's message is the only
		# thing that says why.
		raw="$(gh pr list --repo "$REPO" --state open --limit 500 \
			--json number,headRefOid --jq 'sort_by(.number) | reverse | .[] | [.number, .headRefOid] | @tsv')" || return 2
	fi
	printf '%s' "$raw"
}

# forge_comments_for <pr> -> the PR's comment timeline as gh returns it
# ({comments: [...]}), or empty on failure. Fetched once per PR and handed to
# each reader in comments.sh, so one request answers the verdict, the re-review
# requests and the rate-limit ledger.
forge_comments_for() {
	gh pr view "$1" --repo "$REPO" --json comments 2>/dev/null || true
}

# forge_member_can_write <login> -> success when the account has admin or write
# access to REPO. FAILS CLOSED: any unreadable answer is a refusal, because the
# caller is deciding whether a stranger may spend the review budget.
#
# `.permission` is the legacy four-value field (admin|write|read|none) and it
# folds the finer roles the way this wants them folded: maintain reports as
# write, triage reports as read. Triage can label and close but cannot push,
# and should not be able to spend the API budget either.
forge_member_can_write() {
	local login="$1" perm
	# The login is interpolated into an API path. GitHub logins are alphanumeric
	# with hyphens; anything else is refused rather than sent.
	[[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	perm="$(gh api "repos/${REPO}/collaborators/${login}/permission" \
		--jq '.permission' 2>/dev/null || true)"
	[[ "$perm" = "admin" || "$perm" = "write" ]]
}

# forge_commit_emails <pr> -> one commit-author email per line, or empty on
# failure.
forge_commit_emails() {
	gh pr view "$1" --repo "$REPO" --json commits \
		--jq '.commits[].authors[].email' 2>/dev/null || true
}

# forge_is_approved <pr> -> success when the forge reports the PR as approved.
#
# `reviewDecision` is GitHub's own summary of the human reviews on a PR, and it
# reports exactly one of APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED or
# nothing at all. Only the first is an approval: the other two both mean the PR
# is still waiting on somebody, and "no decision" is what an unreviewed PR in a
# repository with no review requirement looks like.
#
# Compared as an exact value rather than a substring, and a lookup that answers
# nothing is not an approval, so a gh failure fails open to reviewing.
#
# Note what this reads and what it does not: reviewDecision is a statement
# about the PR's current review state, not about the commit that state was
# reached on. GitHub keeps an approval across later pushes unless the branch is
# protected with "dismiss stale approvals", so a PR approved and then pushed to
# still reports APPROVED here and is still skipped. That is the flag doing what
# it says; a run that wants those commits looked at leaves it off.
forge_is_approved() {
	local decision
	decision="$(gh pr view "$1" --repo "$REPO" --json reviewDecision \
		--jq '.reviewDecision // ""' 2>/dev/null || true)"
	[[ "$decision" = "APPROVED" ]]
}

# forge_pr_meta <pr> -> gh's {changedFiles, author, files} JSON, or empty on
# failure. effort_for reads `.author.is_bot` and `.files[].path` from it.
forge_pr_meta() {
	gh pr view "$1" --repo "$REPO" \
		--json changedFiles,author,files 2>/dev/null || true
}

# forge_post_comment <pr> <body-file> -> success when the comment was posted.
forge_post_comment() {
	gh pr comment "$1" --repo "$REPO" --body-file "$2" >/dev/null 2>&1
}

# forge_pr_url <pr> -> the PR's web URL.
forge_pr_url() {
	printf 'https://github.com/%s/pull/%s' "$REPO" "$1"
}

# forge_pr_label <pr> -> how this forge names a PR in display text.
forge_pr_label() {
	printf '#%s' "$1"
}
